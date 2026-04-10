#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-cleanup.sh — Phase 8: Cleanup
# ==================================================

# migrate_phase_cleanup <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 7: Cleanup
set -euo pipefail

migrate_phase_cleanup() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${BLUE}Phase 8: Cleanup${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  warn "This phase will remove old containers and volumes."
  warn "Ensure backups are complete before proceeding."
  echo ""
  if ! confirm "Proceed with cleanup?"; then
    log "Cleanup skipped. Old containers remain stopped."
    return 0
  fi

  local stack_names="${MIGRATION_STACKS:-}"
  if [ -z "$stack_names" ]; then
    warn "No stacks to clean up."
    return 0
  fi

  IFS=',' read -ra STACKS <<<"$stack_names"

  for stack in "${STACKS[@]}"; do
    stack=$(echo "$stack" | xargs)

    echo ""
    echo "Cleaning up old containers for: $stack"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Sudo prefix for docker commands (VPS_SUDO=true for hosts where
    # the deploy user is not in the docker group)
    local _sudo
    _sudo="$(vps_sudo_prefix)"

    # List stopped containers
    local old_containers
    old_containers=$(ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "${_sudo}docker ps -a --format '{{.Names}}' | grep -i $stack | grep -v '$stack-prod'" || echo "")

    if [ -n "$old_containers" ]; then
      echo "Old containers:"
      echo "$old_containers" | sed 's/^/  - /'
      echo ""
      if confirm "Remove these containers?"; then
        for container in $old_containers; do
          ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "${_sudo}docker rm $container"
          ok "Removed: $container"
        done
      fi
    fi
  done

  # Docker cleanup
  echo ""
  if confirm "Run docker system prune?"; then
    log "Running docker system prune..."
    ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "${_sudo}docker system prune -f"
    ok "Docker cleanup complete"
  fi

  ok "Cleanup complete"
}
