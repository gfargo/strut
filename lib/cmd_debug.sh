#!/usr/bin/env bash
# ==================================================
# cmd_debug.sh — Debug command handler
# ==================================================
# Parses its own positional args from CMD_ARGS.

set -euo pipefail

# cmd_debug <stack> <env_file> [subcmd] [service] [args...]
cmd_debug() {
  local stack="$1"
  local env_file="$2"
  shift 2

  validate_env_file "$env_file"

  local subcmd="${1:-}"
  local service="${2:-}"
  shift 2 || shift $#

  [ -n "$subcmd" ] || fail "Usage: strut $stack debug <command> <service> [options]"

  _debug_dispatch "$stack" "$env_file" "$subcmd" "$service" "$@"
}

# cmd_env_debug <stack> <env_prefix> <env_file> [subcmd] [service] [args...]
#
# Handles: strut <stack> local|prod|staging|dev debug <subcmd> <service> [options]
cmd_env_debug() {
  local stack="$1"
  local env_prefix="$2"
  local env_file="$3"
  shift 3

  local subcmd="${1:-}"
  local service="${2:-}"
  shift 2 || shift $#

  [ -n "$subcmd" ] || fail "Usage: strut $stack $env_prefix debug <command> <service> [options]"

  _debug_dispatch "$stack" "$env_file" "$subcmd" "$service" "$@"
}

# _debug_dispatch <stack> <env_file> <subcmd> <service> [remaining_args...]
_debug_dispatch() {
  local stack="$1"
  local env_file="$2"
  local subcmd="$3"
  local service="${4:-}"
  shift 4 || shift $#

  case "$subcmd" in
    exec)
      [ -n "$service" ] || fail "Usage: strut $stack debug exec <service> <command>"
      local cmd="${*}"
      [ -n "$cmd" ] || fail "Usage: strut $stack debug exec <service> <command>"
      debug_exec "$stack" "$service" "$cmd" "$env_file"
      ;;
    shell)
      [ -n "$service" ] || fail "Usage: strut $stack debug shell <service>"
      debug_shell "$stack" "$service" "$env_file"
      ;;
    port-forward)
      [ -n "$service" ] || fail "Usage: strut $stack debug port-forward <service> <local>:<remote>"
      local port_mapping="${1:-}"
      [ -n "$port_mapping" ] || fail "Usage: strut $stack debug port-forward <service> <local>:<remote>"
      if [[ "$port_mapping" =~ ^([0-9]+):([0-9]+)$ ]]; then
        debug_port_forward "$stack" "$service" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$env_file"
      else
        fail "Invalid port mapping format. Use: <local_port>:<remote_port>"
      fi
      ;;
    copy)
      [ -n "$service" ] || fail "Usage: strut $stack debug copy <service> <source> <dest>"
      local source_path="${1:-}"
      local dest_path="${2:-}"
      [ -n "$source_path" ] || fail "Usage: strut $stack debug copy <service> <source> <dest>"
      [ -n "$dest_path" ] || fail "Usage: strut $stack debug copy <service> <source> <dest>"
      debug_copy "$stack" "$service" "$source_path" "$dest_path" "$env_file"
      ;;
    snapshot)
      [ -n "$service" ] || fail "Usage: strut $stack debug snapshot <service>"
      debug_snapshot "$stack" "$service" "$env_file"
      ;;
    inspect-env)
      [ -n "$service" ] || fail "Usage: strut $stack debug inspect-env <service>"
      debug_inspect_env "$stack" "$service" "$env_file"
      ;;
    stats)
      [ -n "$service" ] || fail "Usage: strut $stack debug stats <service>"
      debug_resource_usage "$stack" "$service" "$env_file"
      ;;
    *)
      fail "Unknown debug command: $subcmd

Available commands:
  exec <service> <command>              Execute command in container
  shell <service>                       Open interactive shell
  port-forward <service> <local>:<remote>
                                        Forward port from container
  copy <service> <source> <dest>        Copy files to/from container
  snapshot <service>                    Create container snapshot
  inspect-env <service>                 Show environment variables
  stats <service>                       Show real-time resource usage

Examples:
  strut $stack debug exec ch-api 'ls -la' --env prod
  strut $stack debug shell postgres --env prod
  strut $stack debug stats neo4j --env prod"
      ;;
  esac
}
