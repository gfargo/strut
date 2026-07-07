#!/usr/bin/env bash
# ==================================================
# lib/connection.sh — Unified host-spec parsing and connection resolution
# ==================================================
# Single source of truth for parsing "user@host:port key_path deploy_dir=/path"
# specs and resolving VPS connection info from topology + env + CLI flags.
#
# Provides:
#   parse_host_spec        — parse a host spec string into components
#   resolve_connection     — unified connection resolution with precedence
#   resolve_connection_env — resolve connection from env file only (no topology)

set -euo pipefail

# parse_host_spec <spec_string>
#
# Parses a host spec string into its components. The canonical format is:
#   [user@]host[:port] [key_path] [deploy_dir=/path]
#
# Sets the following variables in the caller's scope:
#   CONN_USER       — SSH user (default: "ubuntu")
#   CONN_HOST       — hostname or IP
#   CONN_PORT       — SSH port (default: "22")
#   CONN_KEY        — SSH key path (default: "")
#   CONN_DEPLOY_DIR — deploy directory override (default: "")
#
# Returns 1 if the spec is empty or unparseable.
#
# Examples:
#   parse_host_spec "ubuntu@10.0.0.1:2222 ~/.ssh/key"
#   parse_host_spec "harbor"        # host only, defaults for rest
#   parse_host_spec "deploy@box:22 /keys/id deploy_dir=/opt/stacks"
parse_host_spec() {
  local spec="$1"

  CONN_USER="ubuntu"
  CONN_HOST=""
  CONN_PORT="22"
  CONN_KEY=""
  CONN_DEPLOY_DIR=""

  [ -n "$spec" ] || return 1

  # Split into words
  local conn_part="" key_or_opt="" extra=""
  read -r conn_part key_or_opt extra <<< "$spec" || true

  # Check for deploy_dir= in second or third position
  local key_path=""
  if [[ "${key_or_opt:-}" == deploy_dir=* ]]; then
    CONN_DEPLOY_DIR="${key_or_opt#deploy_dir=}"
  elif [ -n "${key_or_opt:-}" ]; then
    key_path="$key_or_opt"
  fi
  if [[ "${extra:-}" == deploy_dir=* ]]; then
    CONN_DEPLOY_DIR="${extra#deploy_dir=}"
  fi

  # Parse user@host:port
  if [[ "$conn_part" == *@* ]]; then
    CONN_USER="${conn_part%%@*}"
    local host_port="${conn_part#*@}"
  else
    local host_port="$conn_part"
  fi

  if [[ "$host_port" == *:* ]]; then
    CONN_HOST="${host_port%%:*}"
    CONN_PORT="${host_port#*:}"
  else
    CONN_HOST="$host_port"
  fi

  CONN_KEY="$key_path"

  [ -n "$CONN_HOST" ] || return 1
  return 0
}

# resolve_connection <stack> <env_name> [--host <alias>]
#
# Unified connection resolution with clear precedence:
#   1. --host <alias> (explicit CLI override, highest priority)
#   2. Topology [stacks] mapping (strut.conf)
#   3. Environment variables (from env file or exported)
#
# After resolution, exports:
#   VPS_HOST, VPS_USER, VPS_PORT, VPS_SSH_KEY, VPS_DEPLOY_DIR
#
# Returns 1 if no host can be resolved.
resolve_connection() {
  local stack="$1"
  local env_name="${2:-prod}"
  shift 2 || true

  local host_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host) host_override="$2"; shift 2 ;;
      --host=*) host_override="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  # Load env file first (lowest priority, provides defaults)
  local env_file
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  env_file="$cli_root/.${env_name}.env"
  if [ -f "$env_file" ]; then
    safe_load_env "$env_file"
  fi

  # Topology (middle priority) — only if topology module is available
  if declare -F topology_load &>/dev/null; then
    topology_load
    if [ -n "$host_override" ]; then
      # --host flag: resolve from topology hosts table
      local host_spec="${_TOPO_HOSTS[$host_override]:-}"
      if [ -n "$host_spec" ]; then
        if parse_host_spec "$host_spec"; then
          export VPS_HOST="$CONN_HOST"
          export VPS_USER="$CONN_USER"
          export VPS_PORT="$CONN_PORT"
          [ -n "$CONN_KEY" ] && export VPS_SSH_KEY="$CONN_KEY"
          [ -n "$CONN_DEPLOY_DIR" ] && export VPS_DEPLOY_DIR="$CONN_DEPLOY_DIR"
          return 0
        fi
      fi
    elif topology_has_host "$stack" 2>/dev/null; then
      # Stack has a topology mapping — apply as defaults (env takes precedence)
      local topo_output
      topo_output=$(topology_resolve_host "$stack" 2>/dev/null) || true
      if [ -n "$topo_output" ]; then
        local t_user t_host t_port t_key
        read -r t_user t_host t_port t_key <<< "$topo_output"
        [ -z "${VPS_HOST:-}" ] && export VPS_HOST="$t_host"
        [ -z "${VPS_USER:-}" ] && export VPS_USER="$t_user"
        [ -z "${VPS_PORT:-}" ] && export VPS_PORT="$t_port"
        [ -z "${VPS_SSH_KEY:-}" ] && [ -n "$t_key" ] && export VPS_SSH_KEY="$t_key"
      fi
    fi
  fi

  # Apply defaults
  VPS_USER="${VPS_USER:-ubuntu}"
  VPS_PORT="${VPS_PORT:-22}"
  VPS_DEPLOY_DIR="${VPS_DEPLOY_DIR:-/home/${VPS_USER}/strut}"
  export VPS_USER VPS_PORT VPS_DEPLOY_DIR

  [ -n "${VPS_HOST:-}" ] || return 1
  export VPS_HOST
  return 0
}

# resolve_connection_from_host_alias <host_alias>
#
# Resolves connection info directly from a topology host alias.
# Does NOT consult env files — used by host-scoped commands like
# gateway, cert, provision, sync that take a host alias directly.
#
# Exports: VPS_HOST, VPS_USER, VPS_PORT, VPS_SSH_KEY, VPS_DEPLOY_DIR
# Falls back to env vars if alias not found in topology.
#
# Returns 1 if host cannot be resolved.
resolve_connection_from_host_alias() {
  local host_alias="$1"

  if declare -F topology_load &>/dev/null; then
    topology_load

    if topology_is_host_alias "$host_alias" 2>/dev/null; then
      local host_spec="${_TOPO_HOSTS[$host_alias]:-}"
      if [ -n "$host_spec" ] && parse_host_spec "$host_spec"; then
        export VPS_HOST="$CONN_HOST"
        export VPS_USER="$CONN_USER"
        export VPS_PORT="$CONN_PORT"
        export VPS_SSH_KEY="${CONN_KEY:-${VPS_SSH_KEY:-}}"
        export VPS_DEPLOY_DIR="${CONN_DEPLOY_DIR:-${VPS_DEPLOY_DIR:-/home/${CONN_USER}/strut}}"
        return 0
      fi
    fi
  fi

  # Fall back to env vars
  [ -n "${VPS_HOST:-}" ] || return 1
  export VPS_HOST
  export VPS_USER="${VPS_USER:-ubuntu}"
  export VPS_PORT="${VPS_PORT:-22}"
  export VPS_DEPLOY_DIR="${VPS_DEPLOY_DIR:-/home/${VPS_USER}/strut}"
  return 0
}
