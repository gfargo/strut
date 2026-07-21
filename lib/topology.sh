#!/usr/bin/env bash
# shellcheck disable=SC2119,SC2120
# ==================================================
# lib/topology.sh — Multi-host topology from strut.conf
# ==================================================
# Parses [hosts] and [stacks] sections from strut.conf to provide
# host-to-stack mapping for multi-host deployments.
#
# Format in strut.conf:
#   [hosts]
#   <alias> = <user>@<host>:<port> <ssh_key>
#
#   [stacks]
#   <stack> = <host_alias>
#
# Provides:
#   topology_load          — parse strut.conf sections into associative arrays
#   topology_resolve_host  — get connection info for a stack
#   topology_list_hosts    — list all defined hosts
#   topology_list_stacks   — list stacks for a given host

set -euo pipefail

# Ensure parse_host_spec is available (defined in lib/connection.sh)
if ! declare -F parse_host_spec &>/dev/null; then
  # shellcheck source=lib/connection.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/connection.sh"
fi

# Global topology state (populated by topology_load)
declare -gA _TOPO_HOSTS=()       # alias → "user@host:port key_path"
declare -gA _TOPO_STACK_HOST=()  # stack → host_alias
_TOPO_LOADED=false

# The host alias whose tracked env layer (env/hosts/<alias>.env) is currently
# in effect for this process, set by topology_apply_to_env or
# topology_apply_host_override. Read by env_apply_layers (lib/utils.sh) so
# the layer can be re-applied after downstream code re-sources the base env
# file (validate_env_file, pull_only_stack, bg_deploy_stack/bg_rollback_stack).
declare -g _TOPO_ACTIVE_HOST_ALIAS=""

# topology_load [config_file]
#
# topology_load [config_file]
#
# Parses [hosts] and [stacks] sections from strut.conf.
# Safe to call multiple times (no-ops after first load).
topology_load() {
  [ "$_TOPO_LOADED" = "true" ] && return 0

  local conf="${1:-${PROJECT_ROOT:-}/strut.conf}"
  [ -f "$conf" ] || return 0  # No config = no topology (not an error)

  local section=""
  local line key val

  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Detect section headers
    # Trailing-whitespace-tolerant, matching config.sh's preprocessor
    # header regex (strut#377) — the two used to disagree, so a header
    # with trailing spaces parsed under one and not the other.
    if [[ "$line" =~ ^\[([a-zA-Z_-]+)\][[:space:]]*$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    # Parse key = value within sections
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Trim trailing whitespace
      val="${val%"${val##*[![:space:]]}"}"

      case "$section" in
        hosts)
          _TOPO_HOSTS["$key"]="$val"
          ;;
        stacks)
          _TOPO_STACK_HOST["$key"]="$val"
          ;;
      esac
    fi
  done < "$conf"

  _TOPO_LOADED=true
}

# topology_resolve_host <stack>
#
# Resolves connection info for a stack from the topology map.
# Outputs space-separated: <user> <host> <port> <ssh_key>
# Returns 1 if the stack has no host mapping.
#
# Usage:
#   read -r user host port key <<< "$(topology_resolve_host my-stack)"
topology_resolve_host() {
  local stack="$1"
  topology_load

  local host_alias="${_TOPO_STACK_HOST[$stack]:-}"
  [ -n "$host_alias" ] || return 1

  local host_spec="${_TOPO_HOSTS[$host_alias]:-}"
  [ -n "$host_spec" ] || return 1

  # Use the shared parser from lib/connection.sh
  if parse_host_spec "$host_spec"; then
    echo "$CONN_USER $CONN_HOST $CONN_PORT $CONN_KEY"
  else
    return 1
  fi
}

# topology_has_host <stack>
#
# Returns 0 if the stack has a host mapping in the topology.
topology_has_host() {
  local stack="$1"
  topology_load
  [ -n "${_TOPO_STACK_HOST[$stack]:-}" ]
}

# topology_is_host_alias <name>
#
# Returns 0 if name matches a defined host alias in [hosts], 1 otherwise.
# Used to detect when a host alias is mistakenly passed to --env.
topology_is_host_alias() {
  local name="$1"
  topology_load
  [ -n "${_TOPO_HOSTS[$name]:-}" ]
}

# topology_stack_host_alias <stack>
#
# Echoes the host alias a stack maps to in [stacks] (empty if unmapped).
topology_stack_host_alias() {
  local stack="$1"
  topology_load
  echo "${_TOPO_STACK_HOST[$stack]:-}"
}

# topology_list_hosts
#
# Lists all defined host aliases, one per line.
topology_list_hosts() {
  topology_load
  local alias
  for alias in "${!_TOPO_HOSTS[@]}"; do
    echo "$alias"
  done | sort
}

# topology_list_stacks [host_alias]
#
# Lists stacks, optionally filtered by host alias.
topology_list_stacks() {
  local filter="${1:-}"
  topology_load
  local stack
  for stack in "${!_TOPO_STACK_HOST[@]}"; do
    if [ -z "$filter" ] || [ "${_TOPO_STACK_HOST[$stack]}" = "$filter" ]; then
      echo "$stack"
    fi
  done | sort
}

# topology_apply_to_env <stack> [stack_dir]
#
# If the stack has a topology mapping, exports VPS_HOST, VPS_USER,
# VPS_PORT, and VPS_SSH_KEY from the topology (unless already set
# in the environment from the env file).
# This allows topology to provide defaults that env files can override.
#
# When stack_dir is given, also applies the tracked per-host env layer
# (env/hosts/<alias>.env) — see topology_apply_host_layer — on the normal
# deploy path, not just when --host is passed explicitly.
topology_apply_to_env() {
  local stack="$1"
  local stack_dir="${2:-}"
  topology_load

  if ! topology_has_host "$stack"; then
    return 0  # No topology for this stack — not an error
  fi

  local user host port key_path
  read -r user host port key_path <<< "$(topology_resolve_host "$stack")"

  # Only set if not already defined (env file takes precedence)
  [ -z "${VPS_HOST:-}" ] && export VPS_HOST="$host"
  [ -z "${VPS_USER:-}" ] && export VPS_USER="$user"
  [ -z "${VPS_PORT:-}" ] && export VPS_PORT="$port"
  [ -z "${VPS_SSH_KEY:-}" ] && [ -n "$key_path" ] && export VPS_SSH_KEY="$key_path"

  local host_alias="${_TOPO_STACK_HOST[$stack]}"
  _TOPO_ACTIVE_HOST_ALIAS="$host_alias"
  if [ -n "$stack_dir" ]; then
    topology_apply_host_layer "$stack" "$host_alias" "$stack_dir"
  fi
}

# topology_apply_host_layer <stack> <host_alias> <stack_dir>
#
# Applies the tracked per-host env layer at stacks/<stack>/env/hosts/<alias>.env,
# if present, via safe_load_env (last-wins over whatever is already loaded).
# This is the reusable cascade primitive: base env → host layer. Safe to call
# repeatedly (idempotent) so callers can re-apply it after any downstream
# re-source of the base env file.
topology_apply_host_layer() {
  local stack="$1" host_alias="$2" stack_dir="$3"

  # host_alias ends up in a filesystem path — reject anything that isn't a
  # plain identifier before building the path.
  [[ "$host_alias" =~ ^[A-Za-z0-9_-]+$ ]] || return 0

  local layer_file="$stack_dir/env/hosts/$host_alias.env"
  [ -f "$layer_file" ] && safe_load_env "$layer_file"
  return 0
}

# topology_apply_host_override <stack> <host_alias> <stack_dir>
#
# When --host is specified, overrides the topology target for this stack
# and layers per-host env overrides on top. Applies (in last-wins order):
#   1. legacy wholesale override: stacks/<stack>/.<host>.env (back-compat)
#   2. tracked layer: stacks/<stack>/env/hosts/<host>.env (new path wins)
#
# This enables deploying the same stack to multiple hosts with different
# env vars (e.g., different ports, hostnames) per host.
topology_apply_host_override() {
  local stack="$1"
  local host_alias="$2"
  local stack_dir="$3"
  topology_load

  local host_spec="${_TOPO_HOSTS[$host_alias]:-}"
  if [ -z "$host_spec" ]; then
    fail "Unknown host alias: '$host_alias'. Check [hosts] in strut.conf."
    return 1
  fi

  # Parse host spec and force-set VPS_* vars (override everything)
  if parse_host_spec "$host_spec"; then
    export VPS_HOST="$CONN_HOST"
    export VPS_USER="$CONN_USER"
    export VPS_PORT="$CONN_PORT"
    [ -n "$CONN_KEY" ] && export VPS_SSH_KEY="$CONN_KEY"
    [ -n "$CONN_DEPLOY_DIR" ] && export VPS_DEPLOY_DIR="$CONN_DEPLOY_DIR"
  fi

  _TOPO_ACTIVE_HOST_ALIAS="$host_alias"

  # Legacy wholesale override (gitignored, back-compat) — sourced first so
  # the tracked layer below wins on any overlapping key.
  local legacy_env="$stack_dir/.$host_alias.env"
  if [ -f "$legacy_env" ]; then
    safe_load_env "$legacy_env"
  fi

  topology_apply_host_layer "$stack" "$host_alias" "$stack_dir"
}
