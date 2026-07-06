#!/usr/bin/env bash
# ==================================================
# cmd_cert.sh — Tailscale HTTPS cert lifecycle management
# ==================================================
# Usage: strut <host> cert:renew [--dry-run]
#        strut <host> cert:status
#
# Manages Tailscale HTTPS certificates on remote hosts. Handles renewal,
# ownership/permission fixes for Caddy, and service reload.
# ==================================================
# Requires: lib/utils.sh, lib/topology.sh sourced first

set -euo pipefail

# ── Configuration defaults ────────────────────────────────────────────────────

# Default cert directory (Caddy convention)
CERT_DIR="${CERT_DIR:-/etc/caddy/certs}"
# Default cert ownership (Caddy runs as caddy user)
CERT_OWNER="${CERT_OWNER:-root:caddy}"
# Default key file permissions
CERT_KEY_MODE="${CERT_KEY_MODE:-640}"

# ── Usage ─────────────────────────────────────────────────────────────────────

_usage_cert_renew() {
  echo "Usage: strut <host> cert:renew [--dry-run]"
  echo "       strut <host> cert:status"
  echo ""
  echo "Manage Tailscale HTTPS certificates on a remote host."
  echo ""
  echo "Commands:"
  echo "  cert:renew   Renew the Tailscale HTTPS cert and reload Caddy"
  echo "  cert:status  Show certificate expiry dates"
  echo ""
  echo "Options:"
  echo "  --dry-run    Show what would be done without executing"
  echo ""
  echo "Convention:"
  echo "  Certs stored at: /etc/caddy/certs/<hostname>.crt and .key"
  echo "  Ownership: root:caddy with key mode 640"
  echo "  Override via: CERT_DIR, CERT_OWNER, CERT_KEY_MODE in strut.conf"
  echo ""
  echo "Examples:"
  echo "  strut harbor cert:renew"
  echo "  strut harbor cert:status"
  echo "  strut harbor cert:renew --dry-run"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# _cert_resolve_hostname <host_alias>
#
# Resolves the Tailscale hostname for a host. Checks:
# 1. TAILSCALE_HOSTNAME in strut.conf or services.conf
# 2. The host alias from topology
# Returns the hostname to stdout.
_cert_resolve_hostname() {
  local host_alias="$1"
  # If explicitly set, use it
  if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
    echo "$TAILSCALE_HOSTNAME"
    return
  fi
  # Default to the host alias (most common for Tailscale MagicDNS)
  echo "$host_alias"
}

# _cert_resolve_connection <host_alias>
#
# Resolves SSH connection info for a host from topology or env vars.
# Sets: _CERT_USER, _CERT_HOST, _CERT_PORT, _CERT_KEY
_cert_resolve_connection() {
  local host_alias="$1"

  source "${STRUT_HOME:-$CLI_ROOT}/lib/topology.sh"
  topology_load

  if topology_is_host_alias "$host_alias" 2>/dev/null; then
    local host_spec="${_TOPO_HOSTS[$host_alias]:-}"
    if [ -n "$host_spec" ]; then
      local conn_part key_path
      conn_part="${host_spec%% *}"
      key_path="${host_spec#* }"
      [ "$key_path" = "$conn_part" ] && key_path=""

      if [[ "$conn_part" == *@* ]]; then
        _CERT_USER="${conn_part%%@*}"
        local host_port="${conn_part#*@}"
      else
        _CERT_USER="ubuntu"
        local host_port="$conn_part"
      fi

      if [[ "$host_port" == *:* ]]; then
        _CERT_HOST="${host_port%%:*}"
        _CERT_PORT="${host_port#*:}"
      else
        _CERT_HOST="$host_port"
        _CERT_PORT="22"
      fi
      _CERT_KEY="$key_path"
      return 0
    fi
  fi

  # Fallback to env vars
  _CERT_HOST="${VPS_HOST:-}"
  _CERT_USER="${VPS_USER:-ubuntu}"
  _CERT_PORT="${VPS_PORT:-22}"
  _CERT_KEY="${VPS_SSH_KEY:-}"

  [ -n "$_CERT_HOST" ] || return 1
}

# ── Commands ──────────────────────────────────────────────────────────────────

# cmd_cert_renew [--dry-run]
cmd_cert_renew() {
  local host_alias="${CMD_STACK:-}"
  local dry_run="${DRY_RUN:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$host_alias" ] || { fail "Host alias required. Usage: strut <host> cert:renew"; return 1; }

  if ! _cert_resolve_connection "$host_alias"; then
    fail "Cannot resolve host for '$host_alias'. Add to [hosts] in strut.conf or set VPS_HOST."
    return 1
  fi

  local ts_hostname
  ts_hostname=$(_cert_resolve_hostname "$host_alias")
  local cert_dir="${CERT_DIR:-/etc/caddy/certs}"
  local cert_file="$cert_dir/${ts_hostname}.crt"
  local key_file="$cert_dir/${ts_hostname}.key"
  local owner="${CERT_OWNER:-root:caddy}"
  local key_mode="${CERT_KEY_MODE:-640}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$_CERT_PORT" -k "$_CERT_KEY" --batch)

  print_banner "Cert Renew: $host_alias"
  log "Host: $_CERT_USER@$_CERT_HOST:$_CERT_PORT"
  log "Tailscale hostname: $ts_hostname"
  log "Cert path: $cert_file"
  log "Key path: $key_file"
  echo ""

  # ── Dry-run ──────────────────────────────────────────────────────────────
  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan:${NC}"
    run_cmd "Ensure cert directory" ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo mkdir -p $cert_dir"
    run_cmd "Renew Tailscale cert" ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo tailscale cert --cert-file $cert_file --key-file $key_file $ts_hostname"
    run_cmd "Set ownership ($owner)" ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo chown $owner $cert_file $key_file"
    run_cmd "Set key permissions ($key_mode)" ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo chmod $key_mode $key_file"
    run_cmd "Reload Caddy" ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo systemctl reload caddy"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # ── Execute ─────────────────────────────────────────────────────────────
  log "[1/4] Ensuring cert directory..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo mkdir -p '$cert_dir'" || fail "Failed to create cert directory"

  log "[2/4] Renewing Tailscale cert for $ts_hostname..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo tailscale cert --cert-file '$cert_file' --key-file '$key_file' '$ts_hostname'" || \
    fail "tailscale cert failed — is Tailscale running with HTTPS enabled?"
  ok "Certificate renewed"

  log "[3/4] Setting ownership and permissions..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo chown $owner '$cert_file' '$key_file' && sudo chmod $key_mode '$key_file'" || \
    fail "Failed to set cert ownership/permissions"
  ok "Ownership: $owner, key mode: $key_mode"

  log "[4/4] Reloading Caddy..."
  # shellcheck disable=SC2029
  if ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "sudo systemctl reload caddy" 2>/dev/null; then
    ok "Caddy reloaded"
  else
    warn "Caddy reload failed — may not be running as systemd service"
  fi

  echo ""
  ok "Certificate renewed for $ts_hostname on $host_alias"
}

# cmd_cert_status
cmd_cert_status() {
  local host_alias="${CMD_STACK:-}"
  local dry_run="${DRY_RUN:-false}"

  [ -n "$host_alias" ] || { fail "Host alias required. Usage: strut <host> cert:status"; return 1; }

  if ! _cert_resolve_connection "$host_alias"; then
    fail "Cannot resolve host for '$host_alias'."
    return 1
  fi

  local ts_hostname
  ts_hostname=$(_cert_resolve_hostname "$host_alias")
  local cert_dir="${CERT_DIR:-/etc/caddy/certs}"
  local cert_file="$cert_dir/${ts_hostname}.crt"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$_CERT_PORT" -k "$_CERT_KEY" --batch)

  print_banner "Cert Status: $host_alias"

  if [ "$dry_run" = "true" ]; then
    run_cmd "Check cert expiry" ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "openssl x509 -in $cert_file -noout -dates"
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # shellcheck disable=SC2029
  local cert_info
  cert_info=$(ssh $ssh_opts "$_CERT_USER@$_CERT_HOST" "openssl x509 -in '$cert_file' -noout -subject -dates -issuer 2>/dev/null" 2>/dev/null) || {
    warn "Cannot read certificate at $cert_file"
    warn "Either the cert doesn't exist or openssl is not installed on the host"
    return 1
  }

  echo "$cert_info"
  echo ""

  # Parse expiry and warn if within 14 days
  local expiry_line
  expiry_line=$(echo "$cert_info" | grep "notAfter=" | cut -d= -f2-)
  if [ -n "$expiry_line" ]; then
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_line" +%s 2>/dev/null || date -jf "%b %d %T %Y %Z" "$expiry_line" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [ "$days_left" -le 0 ]; then
      error "Certificate EXPIRED"
      return 1
    elif [ "$days_left" -le 14 ]; then
      warn "Certificate expires in $days_left days — renew soon!"
    else
      ok "Certificate valid for $days_left more days"
    fi
  fi
}
