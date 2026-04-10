#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-audit.sh — Phase 3: Audit existing setup
# ==================================================

# migrate_phase_audit <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 3: Audit existing setup
set -euo pipefail

migrate_phase_audit() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${BLUE}Phase 3: Audit Existing Setup${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  log "Running comprehensive audit..."

  # Run audit command (audit.sh already handles SSH)
  audit_vps "$vps_host" "$vps_user" "$ssh_key" "$ssh_port"

  # Find the audit directory
  local audit_dir
  audit_dir=$(ls -td "$CLI_ROOT/audits"/*-"$vps_host" 2>/dev/null | head -1)

  if [ -z "$audit_dir" ]; then
    fail "Audit failed - no audit directory found"
  fi

  ok "Audit complete: $audit_dir"

  # Show summary
  echo ""
  echo "Audit Summary:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Container count
  local container_count
  container_count=$(wc -l <"$audit_dir/containers.jsonl" 2>/dev/null || echo "0")
  echo "  Containers: $container_count"

  # Volume count
  local volume_count
  volume_count=$(wc -l <"$audit_dir/volumes.jsonl" 2>/dev/null || echo "0")
  echo "  Volumes: $volume_count"

  # Nginx
  if [ -s "$audit_dir/nginx/nginx-containers.txt" ]; then
    echo "  Nginx: Found (containerized)"
  elif [ -f "$audit_dir/nginx/system-nginx.conf" ]; then
    echo "  Nginx: Found (system service)"
  else
    echo "  Nginx: Not found"
  fi

  # Keys
  if [ -f "$audit_dir/keys/all-env-keys.txt" ]; then
    local key_count
    key_count=$(wc -l <"$audit_dir/keys/all-env-keys.txt" 2>/dev/null || echo "0")
    echo "  Environment Keys: $key_count"
  fi

  echo ""
  echo "Review full report: cat $audit_dir/REPORT.md"
  echo "Review stack suggestions: cat $audit_dir/STACK_SUGGESTIONS.md"
  echo ""

  if ! confirm "Continue to stack generation?"; then
    log "Migration paused. Review audit and run wizard again to continue."
    exit 0
  fi

  # Store audit dir for next phases
  export MIGRATION_AUDIT_DIR="$audit_dir"
}
