#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-preflight.sh — Phase 1: Pre-flight checks
# ==================================================

# migrate_phase_preflight <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 1: Pre-flight checks
set -euo pipefail

migrate_phase_preflight() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${BLUE}Phase 1: Pre-flight Checks${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Check SSH connectivity
  local port_display=""
  [ -n "$ssh_port" ] && port_display=":$ssh_port"
  log "Testing SSH connection to $vps_host$port_display..."

  if test_ssh_connection "$vps_user" "$vps_host" "$ssh_port" "$ssh_key"; then
    ok "SSH connection successful"
  else
    fail "Cannot connect to VPS via SSH. Please check:\n  - VPS is reachable\n  - SSH key is configured\n  - User has access\n  - Port is correct"
  fi

  # Check Docker on VPS
  log "Checking Docker installation..."
  if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "command -v docker &>/dev/null"; then
    ok "Docker is installed"

    # Quick check: can we run docker without sudo?
    if ! ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "docker info &>/dev/null" 2>/dev/null; then
      # Try with sudo
      if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "sudo docker info &>/dev/null" 2>/dev/null; then
        warn "Docker requires sudo on this VPS (user not in docker group)"
        export VPS_SUDO=true
      fi
    fi
  else
    warn "Docker not found on VPS"
    if confirm "Install Docker now?"; then
      log "Installing Docker..."
      ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
        "curl -fsSL https://get.docker.com | bash && sudo usermod -aG docker $vps_user"
      ok "Docker installed. Please log out and back in to VPS for group changes to take effect."
      warn "After logging back in, re-run this wizard."
      exit 0
    else
      fail "Docker is required for strut"
    fi
  fi

  # Check disk space
  log "Checking disk space..."
  local disk_usage
  disk_usage=$(ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "df -h / | tail -1 | awk '{print \$5}' | sed 's/%//'")
  if [ "$disk_usage" -lt 80 ]; then
    ok "Disk space: ${disk_usage}% used"
  else
    warn "Disk space: ${disk_usage}% used (high)"
  fi

  # Check running containers (use sudo if VPS_SUDO is set)
  local _sudo
  _sudo="$(vps_sudo_prefix)"
  log "Checking existing containers..."
  local container_count
  container_count=$(ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "${_sudo}docker ps -q | wc -l" 2>/dev/null || echo "0")

  # Auto-detect: if we got 0 containers without sudo, try with sudo
  if [ "$container_count" = "0" ] && [ -z "$_sudo" ]; then
    local sudo_count
    sudo_count=$(ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "sudo docker ps -q 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    if [ "$sudo_count" -gt 0 ]; then
      warn "Docker requires sudo on this VPS ($sudo_count containers found with sudo)"
      export VPS_SUDO=true
      _sudo="sudo "
      container_count="$sudo_count"
    fi
  fi

  log "Found $container_count running containers"

  ok "Pre-flight checks complete"
  echo ""
  if ! confirm "Continue to setup?"; then
    log "Migration paused. Run wizard again to continue."
    exit 0
  fi
}
