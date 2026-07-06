#!/usr/bin/env bash
# ==================================================
# lib/deploy.sh — Deploy orchestration logic
# ==================================================
# Requires: lib/utils.sh, lib/docker.sh sourced first.
# Sources lib/fleet.sh automatically if fleet_sync is not already available.

# Source fleet.sh if not already loaded (provides fleet_sync used by vps_update_repo)
if ! declare -f fleet_sync >/dev/null 2>&1; then
  # shellcheck source=lib/fleet.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet.sh"
fi

# render_safe_clean_snippet <force_clean>
#
# Emits a remote-shell snippet (as a string) that performs a safe git clean:
#   1. Dry-run git clean -fdn to detect what would be removed.
#   2. If nothing: run git clean -fd normally.
#   3. If something and force_clean=true: run git clean -fd (operator override).
#   4. If something and force_clean=false: abort with guidance.
#
# Used by lib/migrate/phase-setup.sh for the migrate update path.
render_safe_clean_snippet() {
  local force_clean="${1:-false}"
  cat <<SNIPPET
__would_remove=\$(git clean -fdn)
if [ -n "\$__would_remove" ]; then
  if [ "$force_clean" = "true" ]; then
    git clean -fd
  else
    echo 'ERROR: git clean would delete untracked paths in the checkout:' >&2
    echo "\$__would_remove" >&2
    echo '' >&2
    echo 'These may be container data dirs or bind-mount sources living inside' >&2
    echo 'the checkout. Move data outside the repo or gitignore the paths, then' >&2
    echo 're-run. To override (data-loss risk), add --force-clean.' >&2
    exit 1
  fi
else
  git clean -fd
fi
SNIPPET
}

# deploy_stack <stack> <env_file> [services_profile]
#
# Brings up the stack at stacks/<stack>/docker-compose.yml using the given
# env file and optional Docker Compose profile for optional service groups.
#
# Arguments:
#   stack           — stack name (must match a directory under stacks/)
#   env_file        — path to .env file (must exist)
#   services_profile — optional Docker Compose profile (messaging|ui|full)
set -euo pipefail

deploy_stack() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  local compose_file="$stack_dir/docker-compose.yml"

  deploy_prepare "$stack" "$stack_dir" "$compose_file" "$env_file"

  # Build compose command via canonical helper
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services_profile")
  local env_name
  env_name=$(extract_env_name "$env_file")

  print_banner "Multi-Service Deploy"
  log "Stack: $stack | Env: $env_name | Services: ${services_profile:-core}"

  # Pre-flight
  log "[1/5] Pre-flight checks..."
  require_cmd docker "Install with: curl -fsSL https://get.docker.com | bash"
  docker compose version &>/dev/null || fail "Docker Compose plugin not found"
  ok "Pre-flight checks passed"

  # Pre-deploy validation (unless skipped)
  if [ "${SKIP_VALIDATION:-false}" != "true" ] && [ "${PRE_DEPLOY_VALIDATE:-true}" = "true" ]; then
    log "[2/7] Pre-deploy validation..."
  fi
  deploy_run_pre_deploy_validation "$stack" "$stack_dir" "$env_file" "$env_name" "$compose_cmd"

  # Dry-run: show execution plan and exit early
  if [ "$DRY_RUN" = "true" ]; then
    load_services_conf "$stack_dir"
    local dry_build_mode="${BUILD_MODE:-registry}"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for deploy (BUILD_MODE=$dry_build_mode):${NC}"
    if [ "$dry_build_mode" = "registry" ]; then
      local registry_type="${REGISTRY_TYPE:-none}"
      if [ "$registry_type" != "none" ]; then
        local registry_host="${REGISTRY_HOST:-}"
        if [ -n "$registry_host" ]; then
          run_cmd "Authenticate with registry ($registry_type: $registry_host)" echo "registry auth"
        else
          run_cmd "Authenticate with registry ($registry_type)" echo "registry auth"
        fi
      fi
      run_cmd "Pull latest images" $compose_cmd pull
    elif [ "$dry_build_mode" = "local" ]; then
      run_cmd "Build images on target" $compose_cmd build
    else
      run_cmd "Skip image pull/build (BUILD_MODE=$dry_build_mode)" echo "skipped"
    fi
    run_cmd "Create data directories" mkdir -p "$stack_dir/data/..."
    run_cmd "Stop existing containers" $compose_cmd down --remove-orphans
    run_cmd "Start services" $compose_cmd up -d --remove-orphans
    local proxy="${REVERSE_PROXY:-nginx}"
    local reload_cmd
    if reload_cmd=$(build_proxy_reload_cmd "$compose_cmd" "$proxy"); then
      run_cmd "Reload reverse proxy" $reload_cmd
    fi
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Load services.conf early so BUILD_MODE and other config is available
  # for the registry/build decision below.
  load_services_conf "$stack_dir"
  local build_mode="${BUILD_MODE:-registry}"

  # Registry login (dispatches based on REGISTRY_TYPE from config)
  # Skipped when BUILD_MODE=local or BUILD_MODE=none (no registry needed)
  if [ "$build_mode" = "registry" ]; then
    log "[2/5] Authenticating with registry..."
    registry_login
  elif [ "$build_mode" = "local" ]; then
    log "[2/5] Skipping registry auth (BUILD_MODE=local)"
  else
    log "[2/5] Skipping registry auth (BUILD_MODE=$build_mode)"
  fi

  # Save rollback snapshot before pulling/building new images
  local strut_home="${STRUT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  source "$strut_home/lib/rollback.sh"
  rollback_save_snapshot "$stack" "$compose_cmd" "$env_name"

  # Pull or build images based on BUILD_MODE
  if [ "$build_mode" = "local" ]; then
    log "[3/5] Building images on target..."
    local build_args="${BUILD_ARGS:-}"
    local build_cmd="$compose_cmd build"
    [ "${BUILD_PULL:-false}" = "true" ] && build_cmd="$build_cmd --pull"
    [ "${BUILD_PARALLEL:-true}" = "true" ] && build_cmd="$build_cmd --parallel"
    [ -n "$build_args" ] && build_cmd="$build_cmd $build_args"
    $build_cmd || fail "Image build failed"
    ok "Images built successfully"
  elif [ "$build_mode" = "none" ]; then
    log "[3/5] Skipping image pull/build (BUILD_MODE=none)"
  else
    log "[3/5] Pulling latest images..."
    docker_pull_stack "$compose_cmd"
    # Abort BEFORE stopping the running stack if a required image is missing
    # (e.g. expired registry token). Prevents tearing the stack down only to
    # fail on restart, or silently deploying stale cached images.
    docker_require_images "$compose_cmd" \
      || fail "Aborting deploy: required images could not be pulled — the running stack was left untouched. Check registry auth (GH_PAT/DOCKER_PASS) and network connectivity."
  fi

  # Data directories — explicit STACK_DATA_DIRS wins; otherwise derive from
  # the same DB_* flags in services.conf that health.sh reads, falling back
  # to a single generic "data" dir when none are set.
  log "[4/5] Creating data directories..."
  local data_dirs="${STACK_DATA_DIRS:-}"
  if [ -z "$data_dirs" ]; then
    [ "${DB_POSTGRES:-false}" = "true" ] && data_dirs="$data_dirs data/postgres"
    [ "${DB_REDIS:-false}" = "true" ] && data_dirs="$data_dirs data/redis"
    [ "${DB_NEO4J:-false}" = "true" ] && data_dirs="$data_dirs data/neo4j"
    [ "${DB_MYSQL:-false}" = "true" ] && data_dirs="$data_dirs data/mysql"
    data_dirs="${data_dirs:-data}"
  fi
  for dir in $data_dirs; do
    mkdir -p "$stack_dir/$dir"
  done
  ok "Data directories ready"

  # Stop any existing containers to free up ports
  log "[5/6] Stopping existing containers..."
  $compose_cmd down --remove-orphans 2>/dev/null || true  # may not be running yet

  # Force-remove any orphaned containers with explicit container_name that
  # docker compose down may have missed (e.g. from a previously failed deploy).
  # We parse container_name values from the compose file and remove them if they
  # still exist — this prevents "name already in use" errors on restart.
  local orphaned_names
  orphaned_names=$(grep -E '^\s+container_name:\s*' "$compose_file" \
    | sed 's/.*container_name:\s*//' | tr -d '"' | tr -d "'" | xargs) || true
  if [ -n "$orphaned_names" ]; then
    for cname in $orphaned_names; do
      if docker inspect "$cname" &>/dev/null; then
        docker rm -f "$cname" 2>/dev/null || true
      fi
    done
  fi

  ok "Existing containers stopped"

  # Bring up stack
  log "[6/6] Starting services..."
  $compose_cmd up -d --remove-orphans

  echo -n "  Waiting for services to start"
  for i in $(seq 1 12); do sleep 5; echo -n "."; done
  echo ""

  # Reload reverse proxy to pick up any new container IPs
  local proxy="${REVERSE_PROXY:-nginx}"
  if $compose_cmd ps "$proxy" &>/dev/null && $compose_cmd ps "$proxy" | grep -q "Up"; then
    log "Reloading $proxy to refresh backend IPs..."
    local reload_cmd
    if reload_cmd=$(build_proxy_reload_cmd "$compose_cmd" "$proxy"); then
      $reload_cmd 2>/dev/null && ok "$proxy reloaded" || warn "$proxy reload failed (may not be critical)"
    fi
  else
    warn "$proxy container not running — skipping reload"
  fi

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✓  Deploy complete (stack: $stack, env: $env_name, services: ${services_profile:-core})${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""

  # Print each service's endpoint from services.conf (*_PORT / *_HEALTH_PATH),
  # mirroring health_check_application's discovery logic.
  local _svc_conf="$stack_dir/services.conf"
  if [ -f "$_svc_conf" ]; then
    local _svc_conf_content
    _svc_conf_content=$(cat "$_svc_conf")
    while IFS='=' read -r _svc_key _svc_value; do
      [[ -z "$_svc_key" || "$_svc_key" =~ ^[[:space:]]*# ]] && continue
      _svc_key=$(echo "$_svc_key" | xargs)
      _svc_value=$(echo "$_svc_value" | xargs)
      [[ "$_svc_key" == DB_* ]] && continue
      [[ "$_svc_key" != *_PORT ]] && continue
      local _svc_prefix="${_svc_key%_PORT}"
      local _svc_name
      _svc_name=$(echo "$_svc_prefix" | tr '[:upper:]_' '[:lower:]-')
      local _svc_health_path
      _svc_health_path=$(echo "$_svc_conf_content" | grep -E "^${_svc_prefix}_HEALTH_PATH=" 2>/dev/null | head -1 | cut -d'=' -f2- | xargs) || true
      echo "  ${_svc_name}: http://localhost:${_svc_value}${_svc_health_path}"
    done <<< "$_svc_conf_content"
  fi
  echo "  Logs:   $compose_cmd logs -f"
  echo "  Status: $compose_cmd ps"
  echo ""

  # Fire post_deploy lifecycle hook (non-fatal on failure)
  # First, run one-time first-run hook if needed (after services are up)
  fire_first_run_hook "$stack_dir" || warn "First-run hook failed — deploy continues"
  # Apply DB schema (opt-in, idempotent) — mirrors the blue-green path
  maybe_apply_db_schema "$stack" "$compose_cmd" "$stack_dir"
  DEPLOY_STATUS="ok" fire_hook_or_warn post_deploy "$stack_dir"

  # Notification providers (Slack/Discord/webhook) subscribed to deploy.success
  notify_event deploy.success \
    stack="$stack" \
    env="$env_name" \
    services="${services_profile:-core}"
}

# vps_update_repo <stack> <env_file>
#
# SSHes into the VPS and updates the strut checkout in VPS_DEPLOY_DIR via
# git fetch + reset --hard, so local drift (dirty files, diverged commits)
# never blocks a deploy. Verifies the strut binary is present and executable
# after the update.
#
# Requires in env file: VPS_HOST, VPS_USER (default: ubuntu)
# Optional:             VPS_SSH_KEY, VPS_DEPLOY_DIR (default: /home/$VPS_USER/strut)
vps_update_repo() {
  local stack="$1"
  local env_file="$2"

  validate_env_file "$env_file" VPS_HOST GH_PAT

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)
  local gh_pat="${GH_PAT:-}"
  local branch="${DEFAULT_BRANCH:-main}"
  local env_name; env_name=$(extract_env_name "$env_file")

  log "Updating strut on $vps_user@$vps_host → $deploy_dir"
  warn "Any local changes on the VPS will be discarded (hard reset to origin/$branch)"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Verify deploy dir exists before syncing
  # Intentional: variables expand locally before SSH
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$vps_user@$vps_host" "[ -d '$deploy_dir' ]" 2>/dev/null; then
    fail "$deploy_dir not found on VPS. strut is not initialized on this host. Run: strut $stack remote:init --env $env_name"
  fi

  # Sync the checkout via fleet_sync (fetch + reset --hard + guarded clean).
  # GH_PAT is forwarded so fetch works regardless of whether the remote is SSH
  # or HTTPS. We use reset --hard rather than pull so local drift on the VPS
  # (modified tracked files, conflicting untracked files) never blocks the sync.
  fleet_sync "$vps_user" "$vps_host" "$vps_port" "$vps_ssh_key" \
    "$deploy_dir" "$branch" "$gh_pat" \
    || fail "Update failed — check VPS_HOST, VPS_SSH_KEY, and VPS_DEPLOY_DIR"

  # Verify strut binary is present and executable after sync
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    if [ ! -f '$deploy_dir/strut' ]; then
      echo 'ERROR: strut binary not found in $deploy_dir after update' >&2
      echo '' >&2
      echo 'The deploy directory exists but does not contain the strut executable.' >&2
      echo 'Run: strut $stack remote:init --env $env_name' >&2
      exit 1
    fi
    chmod +x '$deploy_dir/strut'
    echo 'strut binary ready'
  " && ok "strut updated on VPS" || fail "Update failed — strut binary missing after sync"
}

# pull_only_stack <stack> <env_file> [services_profile]
# Only pulls images without starting services.
# When BUILD_MODE=local, builds images instead of pulling.
pull_only_stack() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"

  if [ ! -f "$env_file" ]; then
    local _hint _msg
    _hint=$(_env_not_found_hint "$env_file")
    _msg="Env file not found: $env_file"
    [ -n "$_hint" ] && _msg="$_msg
$_hint"
    fail "$_msg"
  fi
  set -a; source "$env_file"; set +a

  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services_profile")

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  load_services_conf "$stack_dir"
  local build_mode="${BUILD_MODE:-registry}"

  if [ "$build_mode" = "local" ]; then
    log "Building images on target (BUILD_MODE=local)..."
    local build_args="${BUILD_ARGS:-}"
    local build_cmd="$compose_cmd build"
    [ "${BUILD_PULL:-false}" = "true" ] && build_cmd="$build_cmd --pull"
    [ "${BUILD_PARALLEL:-true}" = "true" ] && build_cmd="$build_cmd --parallel"
    [ -n "$build_args" ] && build_cmd="$build_cmd $build_args"
    $build_cmd || fail "Image build failed"
    ok "Build complete."
  elif [ "$build_mode" = "none" ]; then
    log "Skipping pull/build (BUILD_MODE=none)"
    ok "Nothing to pull or build."
  else
    registry_login
    docker_pull_stack "$compose_cmd"
    ok "Pull complete."
  fi
}

# vps_release <stack> <env_file> [services_profile]
#
# Complete release workflow for VPS deployment:
# 1. Update strut repo on VPS
# 2. Run database migrations (Postgres + Neo4j)
# 3. Pull latest container images
# 4. Restart services
# 5. Verify deployment
#
# This is the recommended way to deploy updates to production.
vps_release() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"

  validate_env_file "$env_file" VPS_HOST

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)
  local env_name
  local env_filename
  env_filename=$(basename "$env_file")

  if [[ "$env_filename" =~ ^\.env\.(.+)$ ]]; then
    env_name="${BASH_REMATCH[1]}"
  elif [[ "$env_filename" =~ ^\.(.+)\.env$ ]]; then
    env_name="${BASH_REMATCH[1]}"
  else
    env_name="prod"
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  print_banner "VPS Release Deploy"
  log "Target: $vps_user@$vps_host"
  log "Stack: $stack | Env: $env_name | Services: ${services_profile:-core}"
  echo ""

  # Dry-run: show execution plan and exit early
  if [ "$DRY_RUN" = "true" ]; then
    local branch="${DEFAULT_BRANCH:-main}"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for release:${NC}"
    run_cmd "Update strut repo on VPS" ssh "$vps_user@$vps_host" "cd $deploy_dir && git fetch && git reset --hard origin/$branch"
    run_cmd "Run Postgres migrations" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack migrate postgres --env $env_name"
    run_cmd "Run Neo4j migrations" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack migrate neo4j --env $env_name"
    run_cmd "Pull latest images" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack deploy --env $env_name --pull-only"
    run_cmd "Restart services" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack deploy --env $env_name"
    run_cmd "Verify deployment" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack health --env $env_name"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Step 1: Update repo
  log "[1/6] Updating strut repository on VPS..."
  vps_update_repo "$stack" "$env_file"

  # Step 2: Run Postgres migrations
  log "[2/6] Running Postgres migrations..."
  local migration_mode="${MIGRATION_FAILURE_MODE:-warn}"
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack migrate postgres --env $env_name
  "; then
    if [ "$migration_mode" = "halt" ]; then
      fail "Postgres migration failed — halting release (MIGRATION_FAILURE_MODE=halt)"
    else
      warn "Postgres migration failed or no migrations to apply"
    fi
  fi

  # Step 3: Run Neo4j migrations
  log "[3/6] Running Neo4j migrations..."
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack migrate neo4j --env $env_name
  "; then
    if [ "$migration_mode" = "halt" ]; then
      fail "Neo4j migration failed — halting release (MIGRATION_FAILURE_MODE=halt)"
    else
      warn "Neo4j migration failed or no migrations to apply"
    fi
  fi

  # Step 4: Pull latest images
  log "[4/6] Pulling latest container images..."
  local profile_flag=""
  [ -n "$services_profile" ] && profile_flag="--services $services_profile"
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack deploy --env $env_name $profile_flag --pull-only
  " || fail "Failed to pull images"

  # Step 5: Restart services
  log "[5/6] Restarting services..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack deploy --env $env_name $profile_flag
  " || fail "Failed to restart services"

  # Step 6: Verify deployment
  log "[6/6] Verifying deployment..."
  sleep 10  # Give services time to start
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack health --env $env_name $profile_flag
  " || warn "Health check failed — check logs with: strut $stack logs --env $env_name"

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✓  Release complete!${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "  Next steps:"
  echo "    View logs:   strut $stack logs <service> --env $env_name --follow"
  echo "    Check status: strut $stack status --env $env_name"
  echo "    SSH to VPS:   strut $stack shell --env $env_name"
  echo ""
}
