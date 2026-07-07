#!/usr/bin/env bash
# ==================================================
# cmd_provision.sh — One-time host bootstrap via provision scripts
# ==================================================
# Usage: strut <host> provision [--script <path>] [--verify] [--dry-run]
#
# Looks for scripts/provision-<host>.sh in the project, SCPs it to the
# target host, and executes it via SSH with TTY allocation for sudo.
# Optionally runs only the verification section with --verify.
# ==================================================
# Requires: lib/utils.sh, lib/topology.sh sourced first

set -euo pipefail

_usage_provision() {
  echo "Usage: strut <host> provision [options]"
  echo ""
  echo "Run a one-time provision script on a remote host."
  echo ""
  echo "Options:"
  echo "  --script <path>   Path to provision script (default: scripts/provision-<host>.sh)"
  echo "  --verify          Run only the verification section of the script"
  echo "  --dry-run         Show what would be done without executing"
  echo ""
  echo "Convention:"
  echo "  Place provision scripts at: scripts/provision-<host-alias>.sh"
  echo "  The script runs on the remote host with sudo access."
  echo ""
  echo "Examples:"
  echo "  strut harbor provision                           # Run scripts/provision-harbor.sh"
  echo "  strut harbor provision --verify                  # Run verification only"
  echo "  strut harbor provision --script ./my-setup.sh    # Custom script"
  echo "  strut harbor provision --dry-run                 # Preview"
}

# _provision_find_script <host_alias> [explicit_path]
#
# Resolves the provision script path. Checks:
# 1. Explicit --script path (if provided)
# 2. scripts/provision-<host>.sh
# 3. infra/scripts/provision-<host>.sh
#
# Outputs the resolved path to stdout, returns 1 if not found.
_provision_find_script() {
  local host_alias="$1"
  local explicit="${2:-}"
  local project_root="${PROJECT_ROOT:-$CLI_ROOT}"

  # Explicit path takes precedence
  if [ -n "$explicit" ]; then
    if [ -f "$explicit" ]; then
      echo "$explicit"
      return 0
    else
      return 1
    fi
  fi

  # Convention-based lookup
  local candidates=(
    "$project_root/scripts/provision-${host_alias}.sh"
    "$project_root/infra/scripts/provision-${host_alias}.sh"
  )

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# _provision_remote_marker <ssh_opts> <user> <host> <deploy_dir>
#
# Checks if the remote host has a .provisioned marker.
# Returns 0 if provisioned, 1 if not.
_provision_remote_marker() {
  local ssh_opts="$1" user="$2" host="$3" deploy_dir="$4"
  # shellcheck disable=SC2029
  ssh $ssh_opts "$user@$host" "test -f '$deploy_dir/.provisioned'" 2>/dev/null
}

# cmd_provision [options]
cmd_provision() {
  local host_alias="${CMD_STACK:-}"
  local dry_run="${DRY_RUN:-false}"
  local verify_only=false
  local script_path=""

  # Parse command-specific flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --script) script_path="$2"; shift 2 ;;
      --verify) verify_only=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$host_alias" ] || { fail "Host alias required. Usage: strut <host> provision"; return 1; }

  # Resolve the provision script
  local script
  if ! script=$(_provision_find_script "$host_alias" "$script_path"); then
    if [ -n "$script_path" ]; then
      fail "Provision script not found: $script_path"
    else
      fail "No provision script found. Expected: scripts/provision-${host_alias}.sh"
    fi
    return 1
  fi

  log "Provision script: $script"

  # Resolve host connection info from topology
  local _strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
  declare -F parse_host_spec &>/dev/null || source "$_strut_home/lib/connection.sh"
  declare -F topology_load &>/dev/null || source "$_strut_home/lib/topology.sh"

  local user host port key_path
  if resolve_connection_from_host_alias "$host_alias"; then
    user="$VPS_USER"
    host="$VPS_HOST"
    port="$VPS_PORT"
    key_path="${VPS_SSH_KEY:-}"
  else
    fail "Cannot resolve host for '$host_alias'. Add to [hosts] in strut.conf or set VPS_HOST."
    return 1
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$port" -k "$key_path" --tty)
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)

  print_banner "Provision: $host_alias"
  log "Target: $user@$host:$port"
  log "Script: $script"
  [ "$verify_only" = "true" ] && log "Mode: verification only"
  echo ""

  # ── Dry-run ──────────────────────────────────────────────────────────────
  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan:${NC}"
    run_cmd "Test SSH connectivity" ssh $ssh_opts "$user@$host" "echo ok"
    run_cmd "Check if already provisioned" ssh $ssh_opts "$user@$host" "test -f $deploy_dir/.provisioned"
    run_cmd "SCP provision script to host" scp $ssh_opts "$script" "$user@$host:/tmp/provision-${host_alias}.sh"
    if [ "$verify_only" = "true" ]; then
      run_cmd "Run verification section" ssh $ssh_opts "$user@$host" "sudo bash /tmp/provision-${host_alias}.sh --verify"
    else
      run_cmd "Execute provision script" ssh $ssh_opts "$user@$host" "sudo bash /tmp/provision-${host_alias}.sh"
      run_cmd "Create provisioned marker" ssh $ssh_opts "$user@$host" "mkdir -p $deploy_dir && echo provisioned > $deploy_dir/.provisioned"
    fi
    run_cmd "Clean up remote script" ssh $ssh_opts "$user@$host" "rm -f /tmp/provision-${host_alias}.sh"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # ── Check if already provisioned ────────────────────────────────────────
  if _provision_remote_marker "$ssh_opts" "$user" "$host" "$deploy_dir"; then
    if [ "$verify_only" = "true" ]; then
      log "Host already provisioned — running verification..."
    else
      warn "Host '$host_alias' appears already provisioned ($deploy_dir/.provisioned exists)"
      warn "Use --verify to re-run verification, or delete the marker to re-provision"
      return 0
    fi
  fi

  # ── Execute ─────────────────────────────────────────────────────────────
  log "Copying provision script to $host..."
  local remote_script="/tmp/provision-${host_alias}.sh"
  scp $ssh_opts "$script" "$user@$host:$remote_script" || fail "Failed to copy script"
  ok "Script uploaded"

  log "Executing provision script..."
  local ssh_cmd="sudo bash $remote_script"
  [ "$verify_only" = "true" ] && ssh_cmd="sudo bash $remote_script --verify"

  # shellcheck disable=SC2029
  if ssh $ssh_opts "$user@$host" "$ssh_cmd"; then
    ok "Provision script completed successfully"

    # Mark as provisioned (only on full provision, not verify)
    if [ "$verify_only" != "true" ]; then
      # shellcheck disable=SC2029
      ssh $ssh_opts "$user@$host" "mkdir -p '$deploy_dir' && date -u +%Y-%m-%dT%H:%M:%SZ > '$deploy_dir/.provisioned'" || true
      ok "Host marked as provisioned"
    fi
  else
    local rc=$?
    error "Provision script failed (exit $rc)"
    return "$rc"
  fi

  # Clean up
  # shellcheck disable=SC2029
  ssh $ssh_opts "$user@$host" "rm -f '$remote_script'" 2>/dev/null || true

  echo ""
  ok "Provisioning complete for $host_alias ($host)"
}
