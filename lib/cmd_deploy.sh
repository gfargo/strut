#!/usr/bin/env bash
# ==================================================
# cmd_deploy.sh — Deploy, update, release, status, prune handlers
# ==================================================

set -euo pipefail

_usage_deploy() {
  echo ""
  echo "Usage: strut <stack> deploy [--env <name>] [--services <profile>] [--pull-only] [--skip-validation] [--dry-run]"
  echo ""
  echo "Deploy stack containers locally. Pulls images, creates data directories,"
  echo "stops existing containers, and starts services."
  echo ""
  echo "Flags:"
  echo "  --env <name>         Environment (reads .<name>.env)"
  echo "  --services <profile> Service profile (messaging|ui|full)"
  echo "  --pull-only          Pull images without restarting containers"
  echo "  --skip-validation    Skip pre-deploy config validation and hooks"
  echo "  --force-unlock       Break an existing deploy lock before acquiring"
  echo "  --no-lock            Skip lock acquisition (advanced; recovery only)"
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

# cmd_deploy [--pull-only] [--skip-validation] [positional...] (reads CMD_*)
cmd_deploy() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"

  # Parse deploy-specific flags
  local pull_only=false
  local skip_validation=false
  local force_unlock=false
  local skip_lock=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pull-only) pull_only=true; shift ;;
      --skip-validation) skip_validation=true; shift ;;
      --force-unlock) force_unlock=true; shift ;;
      --no-lock) skip_lock=true; shift ;;
      *) shift ;;
    esac
  done

  # Export for deploy_stack to read
  export SKIP_VALIDATION="$skip_validation"

  # ── Concurrency lock ─────────────────────────────────────────────────────
  # Prevents two deploys racing against the same stack/env. Honor --no-lock
  # escape hatch for specialized recovery flows, and --force-unlock to break
  # stale locks from a previous crashed deploy.
  if [ "$skip_lock" != "true" ] && [ "$DRY_RUN" != "true" ]; then
    local _env_key="${env_name:-default}"
    if [ "$force_unlock" = "true" ]; then
      warn "Breaking any existing deploy lock (--force-unlock)"
      lock_force_break_local "$stack" "$_env_key" || true
    fi
    if ! lock_acquire_local "$stack" "$_env_key" "deploy"; then
      if lock_is_stale_local "$stack" "$_env_key"; then
        warn "Existing deploy lock appears stale — retry with --force-unlock"
      else
        warn "Re-run with --force-unlock if you're sure the previous deploy is gone"
      fi
      fail "Deploy lock held — aborting"
    fi
    # Ensure lock is released no matter how we exit. Register with the
    # entrypoint's unified cleanup chain so we don't clobber other traps.
    if declare -F strut_register_cleanup >/dev/null; then
      strut_register_cleanup "lock_release_local '$stack' '$_env_key'"
    fi
  fi

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

# cmd_prune [--volumes] [--all] [--no-protect]
#
# Forwards flags through to docker_prune, automatically scoping the prune to
# the current stack so rollback snapshots can protect their referenced images
# from deletion. Opt out with --no-protect or PRUNE_PROTECT_ROLLBACK_IMAGES=false.
cmd_prune() {
  local -a args=()
  local protect=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-protect) protect=false; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  # Default to --volumes when caller passed no flags (preserves prior behavior).
  [ "${#args[@]}" -eq 0 ] && args=(--volumes)

  if [ "$protect" = "true" ] && [ -n "${CMD_STACK:-}" ]; then
    args+=(--stack "$CMD_STACK")
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for prune:${NC}"
    run_cmd "Docker system prune" docker system prune -af "${args[@]}"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi
  docker_prune "${args[@]}"
}
