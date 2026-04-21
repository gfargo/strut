#!/usr/bin/env bash
# ==================================================
# cmd_logs.sh — Logs command handler
# ==================================================

set -euo pipefail

_usage_logs() {
  echo ""
  echo "Usage: strut <stack> logs [--env <name>] [service] [--follow|-f] [--since <duration>]"
  echo ""
  echo "View service logs from a running stack."
  echo ""
  echo "Flags:"
  echo "  --env <name>         Environment (reads .<name>.env)"
  echo "  --follow, -f         Follow log output (tail -f)"
  echo "  --since <duration>   Show logs since duration (e.g. 1h, 30m)"
  echo ""
  echo "Related commands:"
  echo "  logs:download        Download logs to file"
  echo "  logs:rotate          Rotate old log files"
  echo ""
  echo "Examples:"
  echo "  strut my-stack logs --env prod"
  echo "  strut my-stack logs --env prod my-service --follow"
  echo "  strut my-stack logs:download --env prod --since 24h"
  echo ""
}

# cmd_logs [service] [--follow|-f] [--since <dur>] (reads CMD_*)
cmd_logs() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"

  local service_arg=""
  local follow_flag=""
  local since_arg=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --follow|-f) follow_flag="--follow"; shift ;;
      --since=*)   since_arg="${1#*=}"; shift ;;
      --since)     since_arg="${2:-}"; shift 2 ;;
      -*) shift ;;
      *)  service_arg="$1"; shift ;;
    esac
  done

  validate_env_file "$env_file"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")
  logs_tail "$compose_cmd" "$service_arg" "$follow_flag" "$since_arg"
}

# cmd_logs_download [service] [--since <dur>] (reads CMD_*)
cmd_logs_download() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"

  local service_arg=""
  local since="24h"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --since=*) since="${1#*=}"; shift ;;
      --since)   since="$2"; shift 2 ;;
      -*) shift ;;
      *)  service_arg="$1"; shift ;;
    esac
  done

  validate_env_file "$env_file"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")
  logs_download "$compose_cmd" "$service_arg" "$since"
}

# cmd_logs_rotate [days]
cmd_logs_rotate() {
  local days="${1:-7}"
  logs_rotate --days "$days"
}
