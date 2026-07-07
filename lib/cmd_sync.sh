#!/usr/bin/env bash
# ==================================================
# lib/cmd_sync.sh — strut sync command handler
# ==================================================
# Brings remote VPS checkouts in sync with origin.
#
# Usage:
#   strut sync <host-alias>          sync a single topology host
#   strut sync --all                 sync all topology hosts (or env-file hosts)
#   strut sync --env <name>          sync the host defined in .<name>.env
#   strut sync [target] --dry-run    preview without making changes
#   strut sync [target] --force-clean remove untracked files (risk: live data)
#
# Requires: lib/utils.sh, lib/fleet.sh, lib/topology.sh sourced first

set -euo pipefail

_usage_sync() {
  echo "Usage: strut sync [<host-alias>|--all] [--env <name>] [--dry-run] [--force-clean]"
  echo ""
  echo "Bring a host's strut checkout in sync with origin (fetch + reset --hard)."
  echo ""
  echo "Arguments:"
  echo "  <host-alias>     Topology host alias (from [hosts] in strut.conf)"
  echo "  --all            Sync all topology hosts; falls back to env files if no topology"
  echo "  --env <name>     Read host connection from .<name>.env"
  echo ""
  echo "Options:"
  echo "  --dry-run        Show what would happen without making changes"
  echo "  --force-clean    Remove untracked files after reset (may delete container data)"
  echo "  --help, -h       Show this message"
  echo ""
  echo "Untracked non-ignored paths (e.g. database volumes checked into the deploy"
  echo "tree) are preserved by default. Use --force-clean to override."
  echo ""
  echo "Examples:"
  echo "  strut sync compass"
  echo "  strut sync --all"
  echo "  strut sync --env prod"
  echo "  strut sync compass --dry-run"
}

# _sync_via_env_file <env_file> [--dry-run] [--force-clean]
#
# Reads VPS connection details from an env file and calls fleet_sync.
_sync_via_env_file() {
  local env_file="$1"
  shift
  local dry_run=false force_clean=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)     dry_run=true;  shift ;;
      --force-clean) force_clean=true; shift ;;
      *)             shift ;;
    esac
  done

  [ -f "$env_file" ] || { warn "Env file not found: $env_file"; return 1; }

  local vps_host="" vps_user="" vps_ssh_key="" vps_port="" deploy_dir="" gh_pat=""

  vps_host=$(grep -E    '^VPS_HOST='       "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
  vps_user=$(grep -E    '^VPS_USER='       "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
  vps_ssh_key=$(grep -E '^VPS_SSH_KEY='    "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
  vps_port=$(grep -E    '^VPS_PORT='       "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
  deploy_dir=$(grep -E  '^VPS_DEPLOY_DIR=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
  gh_pat=$(grep -E      '^GH_PAT='         "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)

  if [ -z "$vps_host" ]; then
    warn "VPS_HOST not set in $(basename "$env_file") — skipping"
    return 1
  fi

  vps_user="${vps_user:-ubuntu}"
  vps_port="${vps_port:-22}"
  deploy_dir="${deploy_dir:-/home/$vps_user/strut}"
  gh_pat="${gh_pat:-${GH_PAT:-}}"

  local branch="${DEFAULT_BRANCH:-main}"
  local env_label
  env_label=$(basename "$env_file")

  log "Syncing $env_label → $vps_user@$vps_host:$deploy_dir (origin/$branch)"

  local sync_flags=()
  $dry_run     && sync_flags+=(--dry-run)
  $force_clean && sync_flags+=(--force-clean)

  fleet_sync "$vps_user" "$vps_host" "$vps_port" "$vps_ssh_key" \
    "$deploy_dir" "$branch" "$gh_pat" "${sync_flags[@]+"${sync_flags[@]}"}" \
    && ok "Synced $env_label ($vps_host)" \
    || { warn "Sync failed for $env_label ($vps_host)"; return 1; }
}

# _sync_via_topology_host <host_alias> [--dry-run] [--force-clean]
#
# Resolves a topology host alias and calls fleet_sync.
_sync_via_topology_host() {
  local host_alias="$1"
  shift
  local dry_run=false force_clean=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)     dry_run=true;  shift ;;
      --force-clean) force_clean=true; shift ;;
      *)             shift ;;
    esac
  done

  topology_load

  if ! topology_is_host_alias "$host_alias"; then
    fail "Unknown host alias: '$host_alias'  (see [hosts] in strut.conf, or use --env <name>)"
    return 1
  fi

  # Resolve connection via the shared primitive
  if ! resolve_connection_from_host_alias "$host_alias"; then
    fail "Failed to resolve topology for host: $host_alias"
    return 1
  fi

  # shellcheck disable=SC2153
  local vps_user="$VPS_USER"
  # shellcheck disable=SC2153
  local vps_host="$VPS_HOST"
  # shellcheck disable=SC2153
  local vps_port="$VPS_PORT"
  local vps_ssh_key="${VPS_SSH_KEY:-}"

  local deploy_dir; deploy_dir=$(resolve_deploy_dir)
  local gh_pat="${GH_PAT:-}"
  local branch="${DEFAULT_BRANCH:-main}"

  log "Syncing topology host '$host_alias' → $vps_user@$vps_host:$deploy_dir (origin/$branch)"

  local sync_flags=()
  $dry_run     && sync_flags+=(--dry-run)
  $force_clean && sync_flags+=(--force-clean)

  fleet_sync "$vps_user" "$vps_host" "$vps_port" "$vps_ssh_key" \
    "$deploy_dir" "$branch" "$gh_pat" "${sync_flags[@]+"${sync_flags[@]}"}" \
    && ok "Synced topology host '$host_alias' ($vps_host)" \
    || { warn "Sync failed for host '$host_alias' ($vps_host)"; return 1; }
}

cmd_sync() {
  local host_alias="" env_name="" dry_run=false force_clean=false all_hosts=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)         all_hosts=true; shift ;;
      --dry-run)     dry_run=true; shift ;;
      --force-clean) force_clean=true; shift ;;
      --env)         env_name="$2"; shift 2 ;;
      --help|-h)     _usage_sync; return 0 ;;
      -*)            warn "Unknown flag: $1"; shift ;;
      *)             host_alias="$1"; shift ;;
    esac
  done

  local cli_root="${CLI_ROOT:-$(pwd)}"
  local sync_flags=()
  $dry_run     && sync_flags+=(--dry-run)
  $force_clean && sync_flags+=(--force-clean)

  # ── Explicit env file ──────────────────────────────────────────────────────
  if [ -n "$env_name" ]; then
    local env_file="$cli_root/.$env_name.env"
    [ -f "$env_file" ] || env_file="$cli_root/${env_name}.env"
    [ -f "$env_file" ] || fail "Env file not found for: $env_name (looked for .$env_name.env)"
    _sync_via_env_file "$env_file" "${sync_flags[@]+"${sync_flags[@]}"}"
    return $?
  fi

  # ── Specific host alias ────────────────────────────────────────────────────
  if [ -n "$host_alias" ]; then
    _sync_via_topology_host "$host_alias" "${sync_flags[@]+"${sync_flags[@]}"}" || return 1
    return $?
  fi

  # ── --all mode ─────────────────────────────────────────────────────────────
  if $all_hosts; then
    topology_load

    local -a hosts=()
    mapfile -t hosts < <(topology_list_hosts 2>/dev/null || true)

    if [ ${#hosts[@]} -gt 0 ]; then
      log "Syncing ${#hosts[@]} topology host(s)..."
      local failed=0
      local alias
      for alias in "${hosts[@]}"; do
        _sync_via_topology_host "$alias" "${sync_flags[@]+"${sync_flags[@]}"}" \
          || failed=$((failed + 1))
      done
      [ "$failed" -eq 0 ] || { warn "$failed host(s) failed to sync"; return 1; }
    else
      # No topology defined — fall back to env files
      log "No topology hosts defined — falling back to env files..."
      local found_any=false failed=0 f
      for f in "$cli_root"/.*env "$cli_root"/.*.env; do
        [ -f "$f" ] || continue
        found_any=true
        _sync_via_env_file "$f" "${sync_flags[@]+"${sync_flags[@]}"}" \
          || failed=$((failed + 1))
      done
      $found_any || { warn "No topology hosts or env files found"; return 1; }
      [ "$failed" -eq 0 ] || { warn "$failed env(s) failed to sync"; return 1; }
    fi
    return 0
  fi

  # ── No args ────────────────────────────────────────────────────────────────
  _usage_sync
  fail "Specify a host alias, --all, or --env <name>"
}
