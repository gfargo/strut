#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-cutover.sh — Phase 7: Cutover
# ==================================================

# migrate_phase_cutover <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 6: Cutover
set -euo pipefail

migrate_phase_cutover() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${YELLOW}Phase 7: Cutover${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  warn "This phase will stop old containers and switch to strut managed stacks."
  warn "This may cause brief downtime."
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

    # List old containers
    log "Finding old containers for $stack..."
    local old_containers
    old_containers=$(ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "${_sudo}docker ps --format '{{.Names}}' | grep -i $stack | grep -v '$stack-prod'" || echo "")

    if [ -n "$old_containers" ]; then
      echo "Old containers found:"
      echo "$old_containers" | sed 's/^/  - /'
      echo ""
      if confirm "Stop these containers?"; then
        log "Stopping old containers..."
        for container in $old_containers; do
          ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "${_sudo}docker stop $container"
          ok "Stopped: $container"
        done
      fi
    else
      log "No old containers found for $stack"
    fi

    # Ensure strut stack is running
    log "Ensuring strut stack is running..."
    ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "cd /home/$vps_user/strut && strut $stack deploy --env $stack-prod"

    # Health check
    log "Running health check..."
    ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "cd /home/$vps_user/strut && strut $stack health --env $stack-prod"

    ok "Cutover complete for $stack"
  done

  ok "All cutover complete"
  echo ""
  if ! confirm "Continue to cleanup?"; then
    log "Migration complete. Cleanup skipped."
    exit 0
  fi
}
