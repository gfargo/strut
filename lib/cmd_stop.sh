#!/usr/bin/env bash
# ==================================================
# lib/cmd_stop.sh — Stop running stack containers
# ==================================================
# Requires: lib/utils.sh, lib/docker.sh sourced first
#
# Provides:
#   cmd_stop [--remove-orphans] [--volumes] (reads CMD_* context variables)

set -euo pipefail

_usage_stop() {
  echo ""
  echo "Usage: strut <stack> stop [--env <name>] [--services <profile>] [--volumes] [--timeout <seconds>]"
  echo ""
  echo "Stop running stack containers."
  echo ""
  echo "Flags:"
  echo "  --env <name>         Environment (reads .<name>.env)"
  echo "  --services <profile> Service profile"
  echo "  --volumes, -v        Remove volumes when stopping"
  echo "  --timeout, -t <sec>  Timeout for graceful shutdown (default: Docker default)"
  echo "  --dry-run            Show execution plan without making changes"
  echo ""
  echo "Examples:"
  echo "  strut my-stack stop --env prod"
  echo "  strut my-stack stop --env prod --volumes"
  echo "  strut my-stack stop --env prod --timeout 30"
  echo ""
}

cmd_stop() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"

  # Parse stop-specific flags
  local remove_volumes=false
  local timeout=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --volumes|-v)  remove_volumes=true; shift ;;
      --timeout=*)   timeout="${1#*=}"; shift ;;
      --timeout|-t)  timeout="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  validate_env_file "$env_file"

  # Blue-green stacks run under a <stack>-<env>-<color> project, not the
  # plain <stack>-<env> one resolve_compose_cmd defaults to — without this,
  # stop targets an empty project and reports success while the active
  # color keeps serving (strut#384).
  declare -F _bg_active_project >/dev/null || source "$LIB/deploy_blue_green.sh"
  local bg_project
  bg_project="$(_bg_active_project "$stack" "$env_name")"

  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services" "$bg_project")

  # Build down args
  local down_args="--remove-orphans"
  $remove_volumes && down_args="$down_args --volumes"
  [ -n "$timeout" ] && down_args="$down_args --timeout $timeout"

  # Check if this is a VPS environment and we're not on the VPS
  if [ -n "${VPS_HOST:-}" ] && ! is_running_on_vps; then
    _stop_remote "$stack" "$env_file" "$env_name" "$services" "$remove_volumes" "$timeout"
  else
    _stop_local "$stack" "$compose_cmd" "$down_args"
  fi
}

# _stop_local <stack> <compose_cmd> <down_args>
_stop_local() {
  local stack="$1"
  local compose_cmd="$2"
  local down_args="$3"

  if [ "${DRY_RUN:-}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for stop:${NC}"
    run_cmd "Stop containers" $compose_cmd down $down_args
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  log "Stopping stack: $stack"
  # shellcheck disable=SC2086
  $compose_cmd down $down_args
  ok "Stack $stack stopped"
}

# _stop_remote <stack> <env_file> <env_name> <services> <remove_volumes> <timeout>
_stop_remote() {
  local stack="$1"
  local env_file="$2"
  local env_name="$3"
  local services="$4"
  local remove_volumes="${5:-false}"
  local timeout="${6:-}"

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  local services_flag=""
  [ -n "$services" ] && services_flag="--services $services"
  # --volumes/--timeout used to be silently dropped here — down_args was
  # built by the caller but never forwarded to the remote invocation
  # (strut#384).
  local volumes_flag=""
  [ "$remove_volumes" = "true" ] && volumes_flag="--volumes"
  local timeout_flag=""
  [ -n "$timeout" ] && timeout_flag="--timeout $timeout"

  if [ "${DRY_RUN:-}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for remote stop:${NC}"
    run_cmd "Stop containers on VPS" ssh "$vps_user@$vps_host" "cd $deploy_dir && strut $stack stop --env $env_name $services_flag $volumes_flag $timeout_flag"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  log "Stopping stack $stack on $vps_user@$vps_host..."

  # shellcheck disable=SC2029,SC2086
  ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    cd '$deploy_dir'
    ./strut $stack stop --env ${env_name:-prod} $services_flag $volumes_flag $timeout_flag
  " && ok "Stack $stack stopped on VPS" \
    || fail "Failed to stop stack on VPS — check VPS_HOST and SSH access"
}
