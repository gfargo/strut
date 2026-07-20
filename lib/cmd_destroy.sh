#!/usr/bin/env bash
# ==================================================
# lib/cmd_destroy.sh — Permanently tear down a stack
# ==================================================
# Requires: lib/utils.sh, lib/docker.sh, lib/hooks.sh sourced first
#
# Provides:
#   cmd_destroy [--timeout <seconds>] (reads CMD_* context variables)
#
# Symmetric counterpart to first_run: fires pre_destroy (can abort) before
# tearing the stack down, then post_destroy (warn-only) after, then removes
# the .strut-initialized marker so a future deploy re-runs first_run cleanly.

set -euo pipefail

_usage_destroy() {
  echo ""
  echo "Usage: strut <stack> destroy [--env <name>] [--services <profile>] [--timeout <seconds>]"
  echo ""
  echo "Permanently tear down a stack: stop containers, remove volumes and"
  echo "orphans, run teardown hooks, and clear the first-run marker."
  echo ""
  echo "Fires pre_destroy (can abort) before teardown and post_destroy"
  echo "(warn-only) after. Everything a stack's first_run hook installs on"
  echo "the host, its post_destroy hook should uninstall."
  echo ""
  echo "Flags:"
  echo "  --env <name>         Environment (reads .<name>.env)"
  echo "  --services <profile> Service profile"
  echo "  --timeout, -t <sec>  Timeout for graceful shutdown (default: Docker default)"
  echo "  --dry-run            Show execution plan without making changes"
  echo ""
  echo "Examples:"
  echo "  strut my-stack destroy --env prod"
  echo "  strut my-stack destroy --env prod --timeout 30"
  echo ""
}

cmd_destroy() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"

  # Parse destroy-specific flags
  local timeout=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --timeout=*)   timeout="${1#*=}"; shift ;;
      --timeout|-t)  timeout="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  validate_env_file "$env_file"

  # Blue-green stacks run under a <stack>-<env>-<color> project, not the
  # plain <stack>-<env> one resolve_compose_cmd defaults to (strut#384).
  declare -F _bg_active_project >/dev/null || source "$LIB/deploy_blue_green.sh"
  local bg_project
  bg_project="$(_bg_active_project "$stack" "$env_name")"

  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services" "$bg_project")

  # Destroy is permanent — always remove orphans and volumes.
  local down_args="--remove-orphans --volumes"
  [ -n "$timeout" ] && down_args="$down_args --timeout $timeout"

  # Check if this is a VPS environment and we're not on the VPS
  if [ -n "${VPS_HOST:-}" ] && ! is_running_on_vps; then
    _destroy_remote "$stack" "$env_file" "$env_name" "$services" "$timeout"
  else
    _destroy_local "$stack" "$stack_dir" "$compose_cmd" "$down_args"
  fi
}

# _destroy_local <stack> <stack_dir> <compose_cmd> <down_args>
_destroy_local() {
  local stack="$1"
  local stack_dir="$2"
  local compose_cmd="$3"
  local down_args="$4"

  if [ "${DRY_RUN:-}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for destroy:${NC}"
    echo -e "  Would run pre_destroy hook (abort on failure)"
    run_cmd "Stop and remove containers" $compose_cmd down $down_args
    echo -e "  Would run post_destroy hook (warn-only on failure)"
    echo -e "  Would remove first-run marker: $(_first_run_marker_path "$stack_dir")"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  if ! fire_hook pre_destroy "$stack_dir"; then
    fail "pre_destroy hook aborted destroy"
    return 1
  fi

  log "Destroying stack: $stack"
  # shellcheck disable=SC2086
  $compose_cmd down $down_args
  ok "Stack $stack destroyed"

  fire_hook_or_warn post_destroy "$stack_dir"
  remove_first_run_marker "$stack_dir"
}

# _destroy_remote <stack> <env_file> <env_name> <services> <timeout>
_destroy_remote() {
  local stack="$1"
  local env_file="$2"
  local env_name="$3"
  local services="$4"
  local timeout="${5:-}"

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  local services_flag=""
  [ -n "$services" ] && services_flag="--services $services"
  local timeout_flag=""
  [ -n "$timeout" ] && timeout_flag="--timeout $timeout"

  if [ "${DRY_RUN:-}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for remote destroy:${NC}"
    run_cmd "Destroy stack on VPS" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack destroy --env ${env_name:-prod} $services_flag $timeout_flag"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  log "Destroying stack $stack on $vps_user@$vps_host..."

  # shellcheck disable=SC2029,SC2086
  ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    cd '$deploy_dir'
    ./strut $stack destroy --env ${env_name:-prod} $services_flag $timeout_flag
  " && ok "Stack $stack destroyed on VPS" \
    || fail "Failed to destroy stack on VPS — check VPS_HOST and SSH access"
}
