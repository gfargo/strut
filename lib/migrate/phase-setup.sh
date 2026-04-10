#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-setup.sh — Phase 2: Setup strut on VPS
# ==================================================

# migrate_phase_setup <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 2: Setup strut on VPS
set -euo pipefail

migrate_phase_setup() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${BLUE}Phase 2: Setup strut on VPS${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local dest_dir="/home/$vps_user/strut"

  # Check if strut already exists
  log "Checking for existing strut installation..."
  if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "test -d $dest_dir"; then
    warn "strut already exists on VPS"
    if confirm "Update existing installation?"; then
      log "Updating strut..."
      warn "Any local changes on the VPS will be discarded (hard reset to origin/main)"
      ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
        "cd $dest_dir && git fetch origin && git reset --hard origin/main && git clean -fd"
      ok "strut updated"
    else
      log "Using existing installation"
    fi
  else
    log "Cloning strut to VPS..."

    # Get git URL
    local git_url
    git_url=$(git remote get-url origin 2>/dev/null || echo "")

    if [ -z "$git_url" ]; then
      warn "Could not detect git remote URL"
      read -p "Enter strut git URL: " git_url
    fi

    # Use the modular setup function
    if ! setup_strut_repo "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$git_url" "$dest_dir"; then
      fail "Failed to setup strut repository"
    fi
  fi

  # Make CLI executable
  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "chmod +x $dest_dir/strut"

  ok "strut setup complete"
  echo ""
  if ! confirm "Continue to audit?"; then
    log "Migration paused. Run wizard again to continue."
    exit 0
  fi
}
