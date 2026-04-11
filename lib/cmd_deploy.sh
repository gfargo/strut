#!/usr/bin/env bash
# ==================================================
# cmd_deploy.sh — Deploy, update, release, status, prune handlers
# ==================================================

set -euo pipefail

_usage_deploy() {
  echo ""
  echo "Usage: strut <stack> deploy [--env <name>] [--services <profile>] [--pull-only] [--dry-run]"
  echo ""
  echo "Deploy stack containers locally. Pulls images, creates data directories,"
  echo "stops existing containers, and starts services."
  echo ""
  echo "Flags:"
  echo "  --env <name>         Environment (reads .<name>.env)"
  echo "  --services <profile> Service profile (messaging|ui|full)"
  echo "  --pull-only          Pull images without restarting containers"
  echo "  --dry-run            Show execution plan without making changes"
  echo ""
  echo "Related commands:"
  echo "  release              Full VPS release (update + migrate + deploy)"
  echo "  stop                 Stop running containers"
  echo "  health               Run health checks after deploy"
  echo ""
  echo "Examples:"
  echo "  strut my-stack deploy --env prod"
  echo "  strut my-stack deploy --env prod --services full"
  echo "  strut my-stack deploy --env prod --pull-only"
  echo "  strut my-stack deploy --env prod --dry-run"
  echo ""
}

_usage_health() {
  echo ""
  echo "Usage: strut <stack> health [--env <name>] [--services <profile>] [--json]"
  echo ""
  echo "Run health checks: Docker daemon, containers, services, network, databases."
  echo ""
  echo "Flags:"
  echo "  --env <name>         Environment (reads .<name>.env)"
  echo "  --services <profile> Service profile"
  echo "  --json               Output results as JSON"
  echo ""
  echo "Examples:"
  echo "  strut my-stack health --env prod"
  echo "  strut my-stack health --env prod --json"
  echo ""
}

# cmd_update (no args — reads CMD_*)
cmd_update() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  validate_env_file "$env_file" VPS_HOST GH_PAT
  vps_update_repo "$stack" "$env_file"
}

# cmd_release (no args — reads CMD_*)
cmd_release() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"
  validate_env_file "$env_file" VPS_HOST
  vps_release "$stack" "$env_file" "$services"
}

# cmd_deploy [--pull-only] [positional...] (reads CMD_*)
cmd_deploy() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"

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

# cmd_health (no args — reads CMD_*)
cmd_health() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"
  local json_flag="$CMD_JSON"

  [ -f "$env_file" ] && { set -a; source "$env_file"; set +a; } 2>/dev/null || true  # env file may not exist for local-only health checks
  local compose_file="$stack_dir/docker-compose.yml"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")
  health_run_all "$stack" "$compose_cmd" "$compose_file" "$json_flag"
}

# cmd_status (no args — reads CMD_*)
cmd_status() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"
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
