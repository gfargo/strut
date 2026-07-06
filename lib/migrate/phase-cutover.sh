#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-cutover.sh — Phase 7: Cutover
# ==================================================

# migrate_phase_cutover <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 6: Cutover
set -euo pipefail

# cutover_sync_stack_artifacts <vps_user> <vps_host> <ssh_port> <ssh_key> <stack> <dest_dir>
# Copies the stack's docker-compose.yml and prod env file onto the VPS.
# Generated stacks are otherwise only ever pushed there via phase 6's
# optional "Test on VPS" branch, so cutover must not assume they exist.
cutover_sync_stack_artifacts() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local stack="$5"
  local dest_dir="$6"

  local compose_file="$CLI_ROOT/stacks/$stack/docker-compose.yml"
  local env_file="$CLI_ROOT/.$stack-prod.env"

  if [ ! -f "$compose_file" ]; then
    warn "Compose file not found: $compose_file"
    return 1
  fi
  if [ ! -f "$env_file" ]; then
    warn "Env file not found: $env_file"
    return 1
  fi

  if ! ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "mkdir -p $dest_dir/stacks/$stack"; then
    warn "Failed to create remote stack directory for $stack"
    return 1
  fi

  local scp_cmd
  scp_cmd=$(build_scp_cmd "$vps_user" "$vps_host" "$ssh_port" "$ssh_key")

  if ! $scp_cmd "$compose_file" \
    "$vps_user@$vps_host:$dest_dir/stacks/$stack/docker-compose.yml"; then
    warn "Failed to copy docker-compose.yml for $stack"
    return 1
  fi

  if ! $scp_cmd "$env_file" \
    "$vps_user@$vps_host:$dest_dir/.$stack-prod.env"; then
    warn "Failed to copy .$stack-prod.env for $stack"
    return 1
  fi

  return 0
}

migrate_phase_cutover() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${YELLOW}Phase 7: Cutover${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  warn "This phase deploys and health-checks the new strut-managed stack"
  warn "BEFORE stopping any old containers. Old containers are only"
  warn "stopped once the new stack is verified healthy."
  echo ""
  if ! confirm "Proceed with cutover?"; then
    log "Cutover cancelled. Old containers still running."
    exit 0
  fi

  local stack_names="${MIGRATION_STACKS:-}"
  if [ -z "$stack_names" ]; then
    warn "No stacks to cutover. Skipping cutover phase."
    return 0
  fi

  local dest_dir="/home/$vps_user/strut"
  local any_failed=false

  IFS=',' read -ra STACKS <<<"$stack_names"

  for stack in "${STACKS[@]}"; do
    stack=$(echo "$stack" | xargs)

    echo ""
    echo "Cutting over stack: $stack"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Sudo prefix for docker commands (VPS_SUDO=true for hosts where
    # the deploy user is not in the docker group)
    local _sudo
    _sudo="$(vps_sudo_prefix)"

    # ── Pre-flight: strut must be installed and invocable on the VPS ─────
    log "Verifying strut is installed on VPS..."
    if ! ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "test -x $dest_dir/strut"; then
      warn "strut not found or not executable at $dest_dir/strut — skipping $stack"
      warn "Old containers for $stack were left untouched."
      any_failed=true
      continue
    fi

    # ── Ensure stack artifacts (compose + env) are on the VPS ────────────
    log "Syncing stack artifacts to VPS..."
    if ! cutover_sync_stack_artifacts "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$stack" "$dest_dir"; then
      warn "Failed to sync artifacts for $stack — skipping cutover for this stack"
      warn "Old containers for $stack were left untouched."
      any_failed=true
      continue
    fi

    # Find old containers now, but don't touch them until the new stack
    # has been deployed and verified healthy below.
    log "Finding old containers for $stack..."
    local old_containers
    old_containers=$(ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "${_sudo}docker ps --format '{{.Names}}' | grep -i $stack | grep -v '$stack-prod'" || echo "")

    # ── Deploy the new stack — old containers are still running ──────────
    log "Deploying new strut-managed stack..."
    warn "If this fails with 'address already in use', old and new stacks are"
    warn "competing for the same ports — a brief stop-old/deploy-new window"
    warn "may be unavoidable for this stack (not automated by this phase)."
    if ! ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "cd $dest_dir && ./strut $stack deploy --env $stack-prod"; then
      warn "Deploy failed for $stack — old containers were never stopped."
      any_failed=true
      continue
    fi

    # ── Health-gate before touching anything on the old stack ────────────
    log "Running health check..."
    if ! ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "cd $dest_dir && ./strut $stack health --env $stack-prod"; then
      warn "Health check failed for $stack — rolling back the new stack."
      if ! ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
        "cd $dest_dir && ./strut $stack stop --env $stack-prod"; then
        warn "Failed to stop the unhealthy new stack for $stack — check it manually on the VPS."
      fi
      warn "Old containers for $stack were never stopped."
      any_failed=true
      continue
    fi

    # ── New stack verified healthy — safe to stop old containers now ─────
    if [ -n "$old_containers" ]; then
      echo "Old containers found:"
      echo "$old_containers" | sed 's/^/  - /'
      echo ""
      if confirm "Stop these containers?"; then
        log "Stopping old containers..."
        for container in $old_containers; do
          if ! ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "${_sudo}docker stop $container"; then
            warn "Failed to stop old container: $container (new stack is already up)"
            continue
          fi
          ok "Stopped: $container"
        done
      fi
    else
      log "No old containers found for $stack"
    fi

    ok "Cutover complete for $stack"
  done

  if [ "$any_failed" = true ]; then
    warn "One or more stacks failed cutover — review the warnings above before cleanup."
  else
    ok "All cutover complete"
  fi
  echo ""
  if ! confirm "Continue to cleanup?"; then
    log "Migration complete. Cleanup skipped."
    exit 0
  fi
}
