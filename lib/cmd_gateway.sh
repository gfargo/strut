#!/usr/bin/env bash
# ==================================================
# cmd_gateway.sh — Caddy gateway management (system service, not container)
# ==================================================
# Usage: strut gateway deploy --host <alias>
#        strut gateway status --host <alias>
#        strut gateway reload --host <alias>
#        strut gateway validate
#
# Manages Caddyfile configs deployed as a system service (not Docker).
# Convention: stacks/gateway/Caddyfile.<host-alias>
#
# This is a "special stack type" — instead of docker-compose, it manages
# a system-level Caddy service via file copy + systemctl reload.
# ==================================================
# Requires: lib/utils.sh, lib/topology.sh sourced first

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

# Remote Caddyfile path (where the active config lives)
GATEWAY_CADDY_PATH="${GATEWAY_CADDY_PATH:-/etc/caddy/Caddyfile}"
# Local gateway stack directory
GATEWAY_STACK_DIR="${GATEWAY_STACK_DIR:-stacks/gateway}"

# ── Usage ─────────────────────────────────────────────────────────────────────

_usage_gateway() {
  echo "Usage: strut gateway <subcommand> --host <alias> [options]"
  echo ""
  echo "Manage Caddy gateway configs deployed as a system service."
  echo ""
  echo "Subcommands:"
  echo "  deploy   Copy host-specific Caddyfile to remote and reload"
  echo "  status   Show Caddy service status on the host"
  echo "  reload   Reload Caddy without deploying new config"
  echo "  validate Validate local Caddyfile syntax (requires caddy binary)"
  echo ""
  echo "Options:"
  echo "  --host <alias>   Target host (from [hosts] in strut.conf)"
  echo "  --dry-run        Preview without executing"
  echo ""
  echo "Convention:"
  echo "  Place host-specific Caddyfiles at:"
  echo "    stacks/gateway/Caddyfile.<host-alias>"
  echo ""
  echo "  Or a shared Caddyfile at:"
  echo "    stacks/gateway/Caddyfile"
  echo ""
  echo "Examples:"
  echo "  strut gateway deploy --host harbor"
  echo "  strut gateway status --host harbor"
  echo "  strut gateway reload --host compass"
  echo "  strut gateway validate"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# _gateway_find_caddyfile <host_alias>
#
# Resolves the Caddyfile to deploy. Checks:
# 1. stacks/gateway/Caddyfile.<host-alias>
# 2. stacks/gateway/Caddyfile (shared fallback)
#
# Outputs path to stdout, returns 1 if not found.
_gateway_find_caddyfile() {
  local host_alias="$1"
  local project_root="${PROJECT_ROOT:-$CLI_ROOT}"
  local gateway_dir="$project_root/$GATEWAY_STACK_DIR"

  # Host-specific first
  local host_file="$gateway_dir/Caddyfile.${host_alias}"
  if [ -f "$host_file" ]; then
    echo "$host_file"
    return 0
  fi

  # Shared fallback
  local shared_file="$gateway_dir/Caddyfile"
  if [ -f "$shared_file" ]; then
    echo "$shared_file"
    return 0
  fi

  return 1
}

# _gateway_resolve_host <host_alias>
#
# Resolves SSH connection info. Sets _GW_USER, _GW_HOST, _GW_PORT, _GW_KEY.
_gateway_resolve_host() {
  local host_alias="$1"

  # Ensure connection primitives are available
  local _strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
  declare -F parse_host_spec &>/dev/null || source "$_strut_home/lib/connection.sh"
  declare -F topology_load &>/dev/null || source "$_strut_home/lib/topology.sh"

  if resolve_connection_from_host_alias "$host_alias"; then
    _GW_USER="$VPS_USER"
    _GW_HOST="$VPS_HOST"
    _GW_PORT="$VPS_PORT"
    _GW_KEY="${VPS_SSH_KEY:-}"
    return 0
  fi

  return 1
}

# ── Subcommands ───────────────────────────────────────────────────────────────

# _gateway_deploy --host <alias> [--dry-run]
_gateway_deploy() {
  local host_alias="" dry_run="${DRY_RUN:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host) host_alias="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$host_alias" ] || { fail "Usage: strut gateway deploy --host <alias>"; return 1; }

  # Find Caddyfile
  local caddyfile
  if ! caddyfile=$(_gateway_find_caddyfile "$host_alias"); then
    fail "No Caddyfile found for host '$host_alias'. Expected: $GATEWAY_STACK_DIR/Caddyfile.$host_alias"
    return 1
  fi

  # Resolve host
  if ! _gateway_resolve_host "$host_alias"; then
    fail "Cannot resolve host '$host_alias'. Add to [hosts] in strut.conf."
    return 1
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$_GW_PORT" -k "$_GW_KEY" --batch)
  # SCP uses -P (uppercase) for port, not -p like SSH
  local scp_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
  [[ -n "$_GW_PORT" && "$_GW_PORT" != "22" ]] && scp_opts="$scp_opts -P $_GW_PORT"
  [[ -n "$_GW_KEY" ]] && scp_opts="$scp_opts -o IdentitiesOnly=yes -i $_GW_KEY"
  local remote_path="${GATEWAY_CADDY_PATH:-/etc/caddy/Caddyfile}"
  local staging_path="/tmp/Caddyfile.new"

  print_banner "Gateway Deploy: $host_alias"
  log "Caddyfile: $caddyfile"
  log "Target: $_GW_USER@$_GW_HOST:$_GW_PORT"
  log "Remote path: $remote_path"
  echo ""

  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan:${NC}"
    run_cmd "Upload new Caddyfile to staging" scp $scp_opts "$caddyfile" "$_GW_USER@$_GW_HOST:$staging_path"
    run_cmd "Validate staged config" ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo caddy validate --config $staging_path"
    run_cmd "Backup current Caddyfile" ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo cp $remote_path ${remote_path}.bak"
    run_cmd "Install Caddyfile (atomic rename)" ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo cp $staging_path ${remote_path}.new && sudo mv ${remote_path}.new $remote_path"
    run_cmd "Reload Caddy" ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo systemctl reload caddy"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Execute
  log "[1/4] Uploading new Caddyfile to staging..."
  scp $scp_opts "$caddyfile" "$_GW_USER@$_GW_HOST:$staging_path" || fail "Upload failed"

  log "[2/4] Validating staged config..."
  # shellcheck disable=SC2029
  if ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo caddy validate --config '$staging_path'" 2>/dev/null; then
    ok "Config valid"
  else
    # shellcheck disable=SC2029
    ssh $ssh_opts "$_GW_USER@$_GW_HOST" "rm -f '$staging_path'" 2>/dev/null || true
    fail "Caddyfile validation failed — not installed"
    return 1
  fi

  log "[3/4] Backing up current Caddyfile and installing..."
  local have_backup=true
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo cp '$remote_path' '${remote_path}.bak'" 2>/dev/null; then
    have_backup=false
  fi

  # shellcheck disable=SC2029
  ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo cp '$staging_path' '${remote_path}.new' && sudo mv '${remote_path}.new' '$remote_path'" || fail "Install failed"
  ok "Caddyfile installed"
  # shellcheck disable=SC2029
  ssh $ssh_opts "$_GW_USER@$_GW_HOST" "rm -f '$staging_path'" 2>/dev/null || true

  log "[4/4] Reloading Caddy..."
  # shellcheck disable=SC2029
  if ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo systemctl reload caddy"; then
    ok "Caddy reloaded"
  else
    if $have_backup; then
      # shellcheck disable=SC2029
      if ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo mv '${remote_path}.bak' '$remote_path' && sudo systemctl reload caddy"; then
        fail "Caddy reload failed — rolled back to previous config"
      else
        fail "Caddy reload failed AND rollback failed — manual intervention required on $_GW_HOST"
      fi
    else
      fail "Caddy reload failed — no previous config to roll back to"
    fi
    return 1
  fi

  echo ""
  ok "Gateway deployed to $host_alias"
}

# _gateway_status --host <alias>
_gateway_status() {
  local host_alias="" dry_run="${DRY_RUN:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host) host_alias="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$host_alias" ] || { fail "Usage: strut gateway status --host <alias>"; return 1; }

  if ! _gateway_resolve_host "$host_alias"; then
    fail "Cannot resolve host '$host_alias'."
    return 1
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$_GW_PORT" -k "$_GW_KEY" --batch)

  if [ "$dry_run" = "true" ]; then
    run_cmd "Check Caddy service status" ssh $ssh_opts "$_GW_USER@$_GW_HOST" "systemctl status caddy"
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  print_banner "Gateway Status: $host_alias"
  # shellcheck disable=SC2029
  ssh $ssh_opts "$_GW_USER@$_GW_HOST" "systemctl status caddy --no-pager 2>/dev/null" || warn "Caddy not running"
}

# _gateway_reload --host <alias>
_gateway_reload() {
  local host_alias="" dry_run="${DRY_RUN:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host) host_alias="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$host_alias" ] || { fail "Usage: strut gateway reload --host <alias>"; return 1; }

  if ! _gateway_resolve_host "$host_alias"; then
    fail "Cannot resolve host '$host_alias'."
    return 1
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$_GW_PORT" -k "$_GW_KEY" --batch)

  if [ "$dry_run" = "true" ]; then
    run_cmd "Reload Caddy" ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo systemctl reload caddy"
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  log "Reloading Caddy on $host_alias..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$_GW_USER@$_GW_HOST" "sudo systemctl reload caddy" || fail "Reload failed"
  ok "Caddy reloaded on $host_alias"
}

# _gateway_validate
_gateway_validate() {
  local project_root="${PROJECT_ROOT:-$CLI_ROOT}"
  local gateway_dir="$project_root/$GATEWAY_STACK_DIR"

  if [ ! -d "$gateway_dir" ]; then
    fail "Gateway stack directory not found: $gateway_dir"
    return 1
  fi

  if ! command -v caddy &>/dev/null; then
    warn "caddy not installed locally — cannot validate syntax"
    warn "Install: brew install caddy (macOS) or see https://caddyserver.com/docs/install"
    return 1
  fi

  local found=false errors=0

  for caddyfile in "$gateway_dir"/Caddyfile*; do
    [ -f "$caddyfile" ] || continue
    found=true
    local name
    name=$(basename "$caddyfile")
    if caddy validate --config "$caddyfile" 2>/dev/null; then
      ok "$name: valid"
    else
      error "$name: invalid"
      errors=$((errors + 1))
    fi
  done

  if ! $found; then
    warn "No Caddyfile* found in $gateway_dir"
    return 0
  fi

  if [ "$errors" -gt 0 ]; then
    fail "$errors Caddyfile(s) have syntax errors"
    return 1
  fi

  ok "All Caddyfiles valid"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

cmd_gateway() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    deploy)   _gateway_deploy "$@" ;;
    status)   _gateway_status "$@" ;;
    reload)   _gateway_reload "$@" ;;
    validate) _gateway_validate "$@" ;;
    ""|help|--help|-h) _usage_gateway ;;
    *)
      error "Unknown gateway subcommand: $subcmd"
      _usage_gateway
      return 1
      ;;
  esac
}
