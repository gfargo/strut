#!/usr/bin/env bash
# ==================================================
# cmd_deploy.sh — Deploy, update, release, status, prune handlers
# ==================================================

set -euo pipefail

# cmd_update <stack> <env_file>
cmd_update() {
  local stack="$1"
  local env_file="$2"
  validate_env_file "$env_file" VPS_HOST GH_PAT
  vps_update_repo "$stack" "$env_file"
}

# cmd_release <stack> <env_file> <services>
cmd_release() {
  local stack="$1"
  local env_file="$2"
  local services="$3"
  validate_env_file "$env_file" VPS_HOST
  vps_release "$stack" "$env_file" "$services"
}

# cmd_deploy <stack> <env_file> <env_name> <services> [--pull-only] [positional...]
cmd_deploy() {
  local stack="$1"
  local env_file="$2"
  local env_name="$3"
  local services="$4"
  shift 4

  # Parse deploy-specific flags
  local pull_only=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pull-only) pull_only=true; shift ;;
      *) shift ;;
    esac
  done

  # Check if this is a VPS environment and warn user (skip if we're ON the VPS)
  if [ -f "$env_file" ]; then
    set -a; source "$env_file"; set +a
    if [ -n "${VPS_HOST:-}" ] && ! is_running_on_vps; then
      warn "Detected VPS environment (VPS_HOST=$VPS_HOST)"
      warn "The 'deploy' command runs locally. For VPS deployment, use:"
      warn "  strut $stack release --env ${env_name:-prod}"
      warn ""
      warn "Or run deploy on the VPS:"
      local deploy_dir="${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut}"
      warn "  strut $stack exec 'cd $deploy_dir && strut $stack deploy --env ${env_name:-prod}' --env ${env_name:-prod}"
      echo ""
      read -p "Continue with local deployment anyway? (yes/no): " -r
      if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        fail "Deployment cancelled by user"
      fi
    fi
  fi

  if $pull_only; then
    pull_only_stack "$stack" "$env_file" "$services"
  else
    deploy_stack "$stack" "$env_file" "$services"
  fi
}

# cmd_health <stack> <stack_dir> <env_file> <services> <json_flag>
cmd_health() {
  local stack="$1"
  local stack_dir="$2"
  local env_file="$3"
  local services="$4"
  local json_flag="$5"

  [ -f "$env_file" ] && { set -a; source "$env_file"; set +a; } 2>/dev/null || true  # env file may not exist for local-only health checks
  local compose_file="$stack_dir/docker-compose.yml"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")
  health_run_all "$stack" "$compose_cmd" "$compose_file" "$json_flag"
}

# cmd_status <stack> <env_file> <services>
cmd_status() {
  local stack="$1"
  local env_file="$2"
  local services="$3"
  validate_env_file "$env_file"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")
  $compose_cmd ps
}

# cmd_prune [--volumes|positional...]
cmd_prune() {
  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for prune:${NC}"
    run_cmd "Docker system prune" docker system prune -af "${1:---volumes}"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi
  docker_prune "${1:---volumes}"
}
