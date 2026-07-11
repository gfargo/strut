#!/usr/bin/env bash
# ==================================================
# cmd_history.sh — `strut <stack> history` command handler
# ==================================================

set -euo pipefail

_usage_history() {
  echo ""
  echo "Usage: strut <stack> history [--env <name>] [--limit N] [--json]"
  echo ""
  echo "Show recent deploy/release/rollback history for a stack. Entries are"
  echo "recorded automatically on release, deploy, and rollback."
  echo ""
  echo "Flags:"
  echo "  --env <name>   Environment (used to resolve VPS dispatch)"
  echo "  --limit N      Number of entries to show (default: 10)"
  echo "  --json         Output as a JSON array"
  echo ""
  echo "Examples:"
  echo "  strut my-stack history --env prod"
  echo "  strut my-stack history --env prod --json --limit 20"
  echo ""
}

# cmd_history [--limit N] [--json] (reads CMD_*)
cmd_history() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  local limit=10
  local json_mode=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --json)  json_mode=true; shift ;;
      --help|-h) _usage_history; return 0 ;;
      *) shift ;;
    esac
  done

  # Prefer remote execution for VPS-mapped stacks — history lives with the
  # deploy dir wherever release/deploy/rollback actually ran, same
  # dispatch pattern as `strut <stack> rollback`.
  [ -f "$env_file" ] && validate_env_file "$env_file" 2>/dev/null
  if should_dispatch_remote; then
    local remote_args="history --limit $limit"
    [ "$json_mode" = "true" ] && remote_args="$remote_args --json"
    run_remote_strut "$stack" "$env_name" "$remote_args"
    return $?
  fi

  declare -F history_list >/dev/null || source "$LIB/history.sh"

  local args=(--limit "$limit")
  [ "$json_mode" = "true" ] && args+=(--json)
  history_list "$stack_dir" "${args[@]}"
}
