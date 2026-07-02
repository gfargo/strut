#!/usr/bin/env bash
# ==================================================
# cmd_deploy.sh — Deploy, update, release, status, prune handlers
# ==================================================

set -euo pipefail

_usage_deploy() {
  echo ""
  echo "Usage: strut <stack> deploy [--env <name>] [--services <profile>] [--pull-only] [--skip-validation] [--blue-green] [--standard] [--dry-run]"
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
  echo "  --blue-green         Stand up new version alongside current, health-gate,"
  echo "                       swap proxy, drain old (overrides DEPLOY_MODE)"
  echo "  --standard           Force in-place deploy (overrides DEPLOY_MODE)"
  echo "  --dry-run            Show execution plan without making changes"
  echo ""
  echo "Related commands:"
  echo "  release              Full VPS release (update + migrate + deploy)"
  echo "  stop                 Stop running containers"
  echo "  health               Run health checks after deploy"
  echo "  rollback             Restore previous deploy (blue-green: flips active color)"
  echo ""
  echo "Examples:"
  echo "  strut my-stack deploy --env prod"
  echo "  strut my-stack deploy --env prod --services full"
  echo "  strut my-stack deploy --env prod --pull-only"
  echo "  strut my-stack deploy --env prod --blue-green"
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

# cmd_rebuild [--no-cache] [--pull] (reads CMD_*)
# Builds images and restarts services. Equivalent to deploy with BUILD_MODE=local.
cmd_rebuild() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"

  # Parse rebuild-specific flags
  local no_cache=false
  local pull_base=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-cache) no_cache=true; shift ;;
      --pull) pull_base=true; shift ;;
      *) shift ;;
    esac
  done

  # Force BUILD_MODE=local for this deploy, with optional flags
  export BUILD_MODE="local"
  if [ "$no_cache" = "true" ]; then
    export BUILD_ARGS="${BUILD_ARGS:+$BUILD_ARGS }--no-cache"
  fi
  if [ "$pull_base" = "true" ]; then
    export BUILD_PULL="true"
  fi

  # Delegate to the standard deploy pipeline
  deploy_stack "$stack" "$env_file" "$services"
}

_usage_rebuild() {
  echo ""
  echo "Usage: strut <stack> rebuild [--env <name>] [--no-cache] [--pull] [--dry-run]"
  echo ""
  echo "Build images on target and restart services."
  echo "Equivalent to deploy with BUILD_MODE=local."
  echo ""
  echo "Options:"
  echo "  --env <name>       Environment (reads .<name>.env)"
  echo "  --no-cache         Build without using cache"
  echo "  --pull             Pull base images before building"
  echo "  --dry-run          Show execution plan without running"
  echo ""
  echo "Examples:"
  echo "  strut hub rebuild --env prod"
  echo "  strut hub rebuild --env prod --no-cache"
  echo ""
}

# cmd_release [--strict] (reads CMD_*)
cmd_release() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"

  # Parse release-specific flags
  local args=("${CMD_ARGS[@]+"${CMD_ARGS[@]}"}")
  for arg in "${args[@]+"${args[@]}"}"; do
    case "$arg" in
      --strict) export MIGRATION_FAILURE_MODE="halt" ;;
    esac
  done

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
  local force_local=false
  # Mode: honor DEPLOY_MODE config default; --blue-green / --standard on the
  # CLI always wins. `mode_flag=""` means "not overridden — use config".
  local mode_flag=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pull-only) pull_only=true; shift ;;
      --skip-validation) skip_validation=true; shift ;;
      --force-unlock) force_unlock=true; shift ;;
      --no-lock) skip_lock=true; shift ;;
      --force-local) force_local=true; shift ;;
      --blue-green) mode_flag="blue-green"; shift ;;
      --standard)   mode_flag="standard";   shift ;;
      *) shift ;;
    esac
  done
  local deploy_mode="${mode_flag:-${DEPLOY_MODE:-standard}}"

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
        warn "Existing deploy lock is stale (owner process dead) — auto-breaking"
        lock_force_break_local "$stack" "$_env_key" || true
        if ! lock_acquire_local "$stack" "$_env_key" "deploy"; then
          fail "Deploy lock held — aborting (could not reacquire after breaking stale lock)"
        fi
      else
        warn "Re-run with --force-unlock if you're sure the previous deploy is gone"
        fail "Deploy lock held — aborting"
      fi
    fi
    # Ensure lock is released no matter how we exit. Register with the
    # entrypoint's unified cleanup chain so we don't clobber other traps.
    if declare -F strut_register_cleanup >/dev/null; then
      strut_register_cleanup "lock_release_local '$stack' '$_env_key'"
    fi
  fi

  # Check if this is a VPS environment and warn user (skip if we're ON the VPS or --force-local)
  if [ "$force_local" != "true" ] && [ -f "$env_file" ]; then
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
      if ! confirm "Continue with local deployment anyway?"; then
        fail "Deployment cancelled by user"
      fi
    fi
  fi

  if $pull_only; then
    pull_only_stack "$stack" "$env_file" "$services"
    return 0
  fi

  case "$deploy_mode" in
    blue-green)
      bg_deploy_stack "$stack" "$env_file" "$services"
      ;;
    standard|*)
      deploy_stack "$stack" "$env_file" "$services"
      ;;
  esac
}

# cmd_health (no args — reads CMD_*)
cmd_health() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"
  local json_flag="$CMD_JSON"

  # Prefer remote execution for stacks that map to a VPS host, so health
  # checks reflect the actual running state rather than local Docker.
  if [ -f "$env_file" ]; then
    validate_env_file "$env_file"
  fi
  if should_dispatch_remote; then
    local remote_args="health"
    if [ -n "$json_flag" ]; then
      remote_args="$remote_args --json"
    fi
    if [ -n "$services" ]; then
      remote_args="$remote_args --services $services"
    fi
    run_remote_strut "$stack" "$env_name" "$remote_args"
    return $?
  fi

  # Local path: run health checks against the local Docker daemon.
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
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"
  validate_env_file "$env_file"

  # Prefer remote execution for stacks that map to a VPS host, so status
  # reflects the real remote containers instead of the (empty) local daemon.
  if should_dispatch_remote; then
    local remote_args="status"
    if [ -n "$services" ]; then
      remote_args="$remote_args --services $services"
    fi
    run_remote_strut "$stack" "$env_name" "$remote_args"
    return $?
  fi

  # Local path: query the local Docker daemon and show where we're looking.
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")
  # Extract the resolved project name for a clear "looking here" message.
  local project_name
  project_name=$(echo "$compose_cmd" | grep -oE '\-\-project\-name [^ ]+' | awk '{print $2}') || true
  log "Querying local Docker daemon — host: local, project: ${project_name:-<unknown>}"
  # shellcheck disable=SC2086
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
