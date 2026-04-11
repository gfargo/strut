#!/usr/bin/env bash
# ==================================================
# cmd_remote.sh — Shell and exec command handlers
# ==================================================

set -euo pipefail

# cmd_shell (no args — reads CMD_*)
cmd_shell() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  validate_env_file "$env_file" VPS_HOST
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key")
  log "Connecting to $vps_user@$VPS_HOST..."
  exec ssh $ssh_opts "$vps_user@$VPS_HOST"
}

# cmd_exec [command...] (reads CMD_*)
cmd_exec() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  local command="${*}"
  validate_env_file "$env_file" VPS_HOST
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  [ -n "$command" ] || fail "Usage: strut $stack exec <command> --env $env_name"
  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$VPS_HOST" "$command"
}
