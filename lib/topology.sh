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

# Global topology state (populated by topology_load)
declare -gA _TOPO_HOSTS=()       # alias → "user@host:port key_path"
declare -gA _TOPO_STACK_HOST=()  # stack → host_alias
_TOPO_LOADED=false

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
    if [[ "$line" =~ ^\[([a-zA-Z_-]+)\]$ ]]; then
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

  # Parse: user@host:port /path/to/key
  local conn_part key_path
  conn_part="${host_spec%% *}"
  key_path="${host_spec#* }"
  # If no space (no key), key_path equals conn_part — clear it
  [ "$key_path" = "$conn_part" ] && key_path=""

  local user host port
  # Parse user@host:port
  if [[ "$conn_part" == *@* ]]; then
    user="${conn_part%%@*}"
    local host_port="${conn_part#*@}"
  else
    user="ubuntu"
    local host_port="$conn_part"
  fi

  if [[ "$host_port" == *:* ]]; then
    host="${host_port%%:*}"
    port="${host_port#*:}"
  else
    host="$host_port"
    port="22"
  fi

  echo "$user $host $port $key_path"
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

# topology_apply_to_env <stack>
#
# If the stack has a topology mapping, exports VPS_HOST, VPS_USER,
# VPS_PORT, and VPS_SSH_KEY from the topology (unless already set
# in the environment from the env file).
# This allows topology to provide defaults that env files can override.
topology_apply_to_env() {
  local stack="$1"
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
}

# topology_apply_host_override <stack> <host_alias> <stack_dir>
#
# When --host is specified, overrides the topology target for this stack
# and sources per-host env overrides from stacks/<stack>/.<host>.env if present.
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
  local conn_part key_path
  conn_part="${host_spec%% *}"
  key_path="${host_spec#* }"
  [ "$key_path" = "$conn_part" ] && key_path=""

  local user host port
  if [[ "$conn_part" == *@* ]]; then
    user="${conn_part%%@*}"
    local host_port="${conn_part#*@}"
  else
    user="ubuntu"
    local host_port="$conn_part"
  fi

  if [[ "$host_port" == *:* ]]; then
    host="${host_port%%:*}"
    port="${host_port#*:}"
  else
    host="$host_port"
    port="22"
  fi

  export VPS_HOST="$host"
  export VPS_USER="$user"
  export VPS_PORT="$port"
  [ -n "$key_path" ] && export VPS_SSH_KEY="$key_path"

  # Source per-host env override if it exists
  local host_env="$stack_dir/.$host_alias.env"
  if [ -f "$host_env" ]; then
    safe_load_env "$host_env"
  fi
}
