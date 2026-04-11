#!/usr/bin/env bash
# ==================================================
# lib/deploy.sh — Deploy orchestration logic
# ==================================================
# Requires: lib/utils.sh, lib/docker.sh sourced first

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

  [ -d "$stack_dir" ]    || fail "Stack not found: $stack (looked in $stack_dir)"
  [ -f "$compose_file" ] || fail "Compose file not found: $compose_file"
  [ -f "$env_file" ]     || fail "Env file not found: $env_file"

  # Source env and validate required vars
  set -a; source "$env_file"; set +a

  # Export volume paths (NEO4J_DATA_PATH, POSTGRES_DATA_PATH, etc.) so
  # docker-compose uses data volume mounts instead of named volumes
  export_volume_paths "$stack_dir"

  # Per-stack required vars — read from stacks/<stack>/required_vars if present,
  # otherwise skip validation entirely (no hardcoded fallback list).
  local required_vars_file="$stack_dir/required_vars"
  if [ -f "$required_vars_file" ]; then
    while IFS= read -r var || [ -n "$var" ]; do
      [ -z "$var" ] && continue
      val="$(eval echo "\${${var}:-}")"
      [ -n "$val" ] || fail "Missing required env var: $var (check $env_file)"
    done < "$required_vars_file"
  fi

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

  # Dry-run: show execution plan and exit early
  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for deploy:${NC}"
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
    run_cmd "Create data directories" mkdir -p "$stack_dir/data/..."
    run_cmd "Stop existing containers" $compose_cmd down --remove-orphans
    run_cmd "Start services" $compose_cmd up -d --remove-orphans
    local proxy="${REVERSE_PROXY:-nginx}"
    case "$proxy" in
      nginx) run_cmd "Reload reverse proxy" $compose_cmd exec -T nginx nginx -s reload ;;
      caddy) run_cmd "Reload reverse proxy" $compose_cmd exec -T caddy caddy reload --config /etc/caddy/Caddyfile ;;
    esac
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Registry login (dispatches based on REGISTRY_TYPE from config)
  log "[2/5] Authenticating with registry..."
  registry_login

  # Save rollback snapshot before pulling new images
  source "$cli_root/lib/rollback.sh"
  rollback_save_snapshot "$stack" "$compose_cmd" "$env_name"

  # Pull images
  log "[3/5] Pulling latest images..."
  docker_pull_stack "$compose_cmd"

  # Data directories — read from services.conf or use defaults
  log "[4/5] Creating data directories..."
  load_services_conf "$stack_dir"
  local data_dirs="${STACK_DATA_DIRS:-data/postgres data/redis data/gdrive}"
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
    case "$proxy" in
      nginx) $compose_cmd exec -T nginx nginx -s reload 2>/dev/null && ok "nginx reloaded" || warn "nginx reload failed (may not be critical)" ;;
      caddy) $compose_cmd exec -T caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null && ok "Caddy reloaded" || warn "Caddy reload failed (may not be critical)" ;;
    esac
  else
    warn "$proxy container not running — skipping reload"
  fi

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✓  Deploy complete (stack: $stack, env: $env_name, services: ${services_profile:-core})${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "  API:    http://localhost:8000/health"
  echo "  Logs:   $compose_cmd logs -f"
  echo "  Status: $compose_cmd ps"
  echo ""
}

# vps_update_repo <stack> <env_file>
#
# SSHes into the VPS and runs `git pull` in VPS_DEPLOY_DIR to bring the
# strut checkout up to date before a deploy.
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
  local deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"
  local gh_pat="${GH_PAT:-}"
  local branch="${DEFAULT_BRANCH:-main}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  log "Updating strut on $vps_user@$vps_host → $deploy_dir"
  warn "Any local changes on the VPS will be discarded (hard reset to origin/$branch)"

  # GH_PAT is passed into the remote shell and used via `git -c url.insteadOf`
  # so the fetch works regardless of whether the remote is SSH or HTTPS.
  #
  # We use fetch + reset --hard rather than pull so that local drift on the VPS
  # (modified tracked files, untracked files that conflict) never blocks the sync.
  # The VPS is a deployment target — it should always be a clean repo mirror.
  # Intentional: variables expand locally before SSH
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    if [ ! -d '$deploy_dir' ]; then
      echo 'ERROR: $deploy_dir not found on VPS' >&2; exit 1
    fi
    cd '$deploy_dir'
    echo '--- Current HEAD ---'
    git log --oneline -1
    echo '--- Fetching ---'
    git \
      -c 'url.https://oauth2:$gh_pat@github.com/.insteadOf=https://github.com/' \
      -c 'url.https://oauth2:$gh_pat@github.com/.insteadOf=git@github.com:' \
      fetch origin
    echo '--- Resetting to origin/$branch ---'
    git reset --hard origin/$branch
    git clean -fd
    echo '--- Updated HEAD ---'
    git log --oneline -1
  " && ok "strut updated on VPS" || fail "Update failed — check VPS_HOST, VPS_SSH_KEY, and VPS_DEPLOY_DIR"
}

# pull_only_stack <stack> <env_file> [services_profile]
# Only pulls images without starting services
pull_only_stack() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"

  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a; source "$env_file"; set +a

  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services_profile")

  registry_login
  docker_pull_stack "$compose_cmd"
  ok "Pull complete."
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
  local deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"
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
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    strut $stack migrate postgres --env $env_name
  " || warn "Postgres migration failed or no migrations to apply"

  # Step 3: Run Neo4j migrations
  log "[3/6] Running Neo4j migrations..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    strut $stack migrate neo4j --env $env_name
  " || warn "Neo4j migration failed or no migrations to apply"

  # Step 4: Pull latest images
  log "[4/6] Pulling latest container images..."
  local profile_flag=""
  [ -n "$services_profile" ] && profile_flag="--services $services_profile"
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    strut $stack deploy --env $env_name $profile_flag --pull-only
  " || fail "Failed to pull images"

  # Step 5: Restart services
  log "[5/6] Restarting services..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    strut $stack deploy --env $env_name $profile_flag
  " || fail "Failed to restart services"

  # Step 6: Verify deployment
  log "[6/6] Verifying deployment..."
  sleep 10  # Give services time to start
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    strut $stack health --env $env_name $profile_flag
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
