#!/usr/bin/env bash
# ==================================================
# cmd_volumes.sh — Volume management command handler
# ==================================================

set -euo pipefail

_usage_volumes() {
  echo ""
  echo "Usage: strut <stack> volumes [--env <name>] <subcommand>"
  echo ""
  echo "Manage data volumes for a stack."
  echo ""
  echo "Subcommands:"
  echo "  status               Show volume paths and ownership"
  echo "  init                 Create volume directories with correct ownership"
  echo "  config               Show volume.conf contents"
  echo ""
  echo "Examples:"
  echo "  strut my-stack volumes status --env prod"
  echo "  strut my-stack volumes init --env prod"
  echo ""
}

# cmd_volumes [action] (reads CMD_*)
cmd_volumes() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local volume_action="${1:-status}"

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
