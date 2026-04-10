#!/usr/bin/env bash
# ==================================================
# cmd_keys.sh — Key management command handler
# ==================================================

set -euo pipefail

# cmd_keys <stack> <env_file> [subcommand] [username] [args...]
cmd_keys() {
  local stack="$1"
  local env_file="$2"
  local subcmd="${3:-}"
  local username="${4:-}"
  shift 4 || shift $#
  keys_command "$stack" "$subcmd" "$username" --env-file "$env_file" "$@"
}
