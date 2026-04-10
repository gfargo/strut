#!/usr/bin/env bash
# ==================================================
# cmd_volumes.sh — Volume management command handler
# ==================================================

set -euo pipefail

# cmd_volumes <stack> <stack_dir> <env_file> [action]
cmd_volumes() {
  local stack="$1"
  local stack_dir="$2"
  local env_file="$3"
  local volume_action="${4:-status}"

  validate_env_file "$env_file"

  local volume_conf="$stack_dir/volume.conf"
  [ -f "$volume_conf" ] && source "$volume_conf"

  case "$volume_action" in
    status)
      log_info "Volume Status for $stack"
      volume_status
      ;;
    init)
      log_info "Initializing volume directories for $stack"
      init_volume_directories "$stack_dir"
      ;;
    config)
      verify_volume_config "$stack_dir"
      ;;
    *)
      validate_subcommand "$volume_action" status init config || exit 1
      ;;
  esac
}
