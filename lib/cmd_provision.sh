#!/usr/bin/env bash
# ==================================================
# cmd_provision.sh — Host bootstrap via provision scripts
# ==================================================
# Usage: strut <host> provision [--script <path>] [--verify] [--force] [--dry-run]
#
# Two models, tried in order:
#
#   1. Directory model (preferred): hosts/<host>/provision.d/NN-*.sh — an
#      ordered batch of scripts, each SCP'd to the host and run in turn,
#      gated by a per-script marker on the host
#      (/var/lib/strut/provisioned/<script>.done) so re-runs only execute
#      what hasn't succeeded yet. `--force` re-runs everything (repair).
#      pre_provision/post_provision hooks fire around the batch from
#      hosts/<host>/hooks/ (see lib/hooks.sh).
#
#   2. Legacy single-script model: scripts/provision-<host>.sh (or
#      infra/scripts/...), SCP'd and run once, gated by a single
#      <deploy_dir>/.provisioned marker. Still used when no provision.d/
#      directory exists for the host, or when --script is passed explicitly.
#      Optionally runs only the verification section with --verify.
# ==================================================
# Requires: lib/utils.sh, lib/hooks.sh, lib/topology.sh sourced first

set -euo pipefail

_usage_provision() {
  echo "Usage: strut <host> provision [options]"
  echo ""
  echo "Run host provisioning: either an ordered hosts/<host>/provision.d/"
  echo "script batch, or a single legacy provision script."
  echo ""
  echo "Options:"
  echo "  --script <path>   Path to a single provision script (legacy model; default: scripts/provision-<host>.sh)"
  echo "  --verify          Run only the verification section of the script (legacy model)"
  echo "  --force           Re-run all provision.d scripts, ignoring existing markers"
  echo "  --dry-run         Show what would be done without executing"
  echo ""
  echo "Convention:"
  echo "  hosts/<host-alias>/provision.d/NN-*.sh   Ordered, marker-gated scripts (preferred)"
  echo "  hosts/<host-alias>/hooks/                pre_provision / post_provision hooks"
  echo "  scripts/provision-<host-alias>.sh        Single legacy script"
  echo "  Scripts run on the remote host with sudo access."
  echo ""
  echo "Examples:"
  echo "  strut harbor provision                           # Run hosts/harbor/provision.d/*.sh (or legacy script)"
  echo "  strut harbor provision --force                   # Re-run all provision.d scripts"
  echo "  strut harbor provision --verify                  # Legacy: run verification only"
  echo "  strut harbor provision --script ./my-setup.sh    # Legacy: custom script"
  echo "  strut harbor provision --dry-run                 # Preview"
}

# _provision_find_scripts_dir <host_alias>
#
# Resolves hosts/<host_alias>/provision.d if it exists and is non-empty.
# Outputs the resolved path to stdout, returns 1 if not found.
_provision_find_scripts_dir() {
  local host_alias="$1"
  local project_root="${PROJECT_ROOT:-$CLI_ROOT}"
  local dir="$project_root/hosts/${host_alias}/provision.d"

  [ -d "$dir" ] || return 1
  echo "$dir"
}

# _provision_host_hooks_dir <host_alias>
#
# Returns the host-scoped hooks directory (may not exist — fire_hook
# tolerates that).
_provision_host_hooks_dir() {
  local host_alias="$1"
  local project_root="${PROJECT_ROOT:-$CLI_ROOT}"
  echo "$project_root/hosts/${host_alias}"
}

# _provision_list_scripts <scripts_dir>
#
# Lists *.sh files directly under scripts_dir, one per line, sorted
# lexically under the C locale so NN- prefixes order deterministically
# regardless of the host's locale settings.
_provision_list_scripts() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | LC_COLLATE=C sort
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

# _provision_run_legacy_model <host_alias> <script_path> <user> <host> <port> <ssh_opts> <dry_run> <verify_only>
#
# Single-script provision model: SCP one script to the host, run it once,
# gate on a single <deploy_dir>/.provisioned marker. Kept for existing
# projects that predate the provision.d/ directory model.
_provision_run_legacy_model() {
  local host_alias="$1" script_path="$2" user="$3" host="$4" port="$5" ssh_opts="$6" dry_run="$7" verify_only="$8"

  local script
  if ! script=$(_provision_find_script "$host_alias" "$script_path"); then
    if [ -n "$script_path" ]; then
      fail "Provision script not found: $script_path"
    else
      fail "No provision script found. Expected: scripts/provision-${host_alias}.sh (or hosts/${host_alias}/provision.d/)"
    fi
    return 1
  fi

  log "Provision script: $script"

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

# _provision_run_dir_model <host_alias> <scripts_dir> <user> <host> <port> <ssh_opts> <dry_run> <force>
#
# Ordered, marker-gated provision.d/ batch. Each script is SCP'd to the
# host and run once via sudo; a per-script marker on the host
# (/var/lib/strut/provisioned/<script>.done) skips scripts that already
# succeeded, unless --force is set. pre_provision/post_provision hooks
# fire around the whole batch (see lib/hooks.sh).
_provision_run_dir_model() {
  local host_alias="$1" scripts_dir="$2" user="$3" host="$4" port="$5" ssh_opts="$6" dry_run="$7" force="$8"
  local marker_dir="/var/lib/strut/provisioned"
  local hooks_dir; hooks_dir=$(_provision_host_hooks_dir "$host_alias")

  local -a scripts=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && scripts+=("$f")
  done < <(_provision_list_scripts "$scripts_dir")

  print_banner "Provision: $host_alias"
  log "Target: $user@$host:$port"
  log "Scripts: $scripts_dir (${#scripts[@]} found)"
  echo ""

  if [ "${#scripts[@]}" -eq 0 ]; then
    warn "No provision.d scripts found in $scripts_dir"
    return 0
  fi

  export PROVISION_HOST="$host_alias"
  export PROVISION_HOST_DIR="$scripts_dir"

  local script name remote_script

  # ── Dry-run ──────────────────────────────────────────────────────────────
  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan:${NC}"
    run_cmd "Test SSH connectivity" ssh $ssh_opts "$user@$host" "echo ok"
    fire_hook pre_provision "$hooks_dir"
    for script in "${scripts[@]}"; do
      name=$(basename "$script" .sh)
      remote_script="/tmp/provision-${host_alias}-${name}.sh"
      if [ "$force" = "true" ]; then
        run_cmd "Run $name (--force: marker ignored)" true
      else
        run_cmd "Check marker: $name" ssh $ssh_opts "$user@$host" "test -f '$marker_dir/${name}.done'"
      fi
      run_cmd "SCP $name to host" scp $ssh_opts "$script" "$user@$host:$remote_script"
      run_cmd "Execute $name" ssh $ssh_opts "$user@$host" "sudo bash $remote_script"
      run_cmd "Write marker for $name" ssh $ssh_opts "$user@$host" "mkdir -p $marker_dir && date -u +%Y-%m-%dT%H:%M:%SZ > $marker_dir/${name}.done"
    done
    fire_hook_or_warn post_provision "$hooks_dir"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # ── pre_provision hook (abort on failure) ───────────────────────────────
  if ! fire_hook pre_provision "$hooks_dir"; then
    fail "pre_provision hook failed — aborting provisioning"
    return 1
  fi

  # ── Execute batch ────────────────────────────────────────────────────────
  local ran=0 skipped=0
  for script in "${scripts[@]}"; do
    name=$(basename "$script" .sh)
    remote_script="/tmp/provision-${host_alias}-${name}.sh"

    if [ "$force" != "true" ] && ssh $ssh_opts "$user@$host" "test -f '$marker_dir/${name}.done'" 2>/dev/null; then
      log "Skipping $name (already provisioned; use --force to re-run)"
      skipped=$((skipped + 1))
      continue
    fi

    log "Provisioning: $name"
    if ! scp $ssh_opts "$script" "$user@$host:$remote_script"; then
      fail "Failed to copy $name to host"
      return 1
    fi

    # shellcheck disable=SC2029
    if ssh $ssh_opts "$user@$host" "sudo bash $remote_script"; then
      # shellcheck disable=SC2029
      ssh $ssh_opts "$user@$host" "mkdir -p '$marker_dir' && date -u +%Y-%m-%dT%H:%M:%SZ > '$marker_dir/${name}.done'" || true
      # shellcheck disable=SC2029
      ssh $ssh_opts "$user@$host" "rm -f '$remote_script'" 2>/dev/null || true
      ok "$name completed"
      ran=$((ran + 1))
    else
      local rc=$?
      # shellcheck disable=SC2029
      ssh $ssh_opts "$user@$host" "rm -f '$remote_script'" 2>/dev/null || true
      error "$name failed (exit $rc)"
      return "$rc"
    fi
  done

  fire_hook_or_warn post_provision "$hooks_dir"

  echo ""
  ok "Provisioning complete for $host_alias ($host): $ran run, $skipped skipped"
}

# cmd_provision [options]
cmd_provision() {
  local host_alias="${CMD_STACK:-}"
  local dry_run="${DRY_RUN:-false}"
  local verify_only=false
  local force=false
  local script_path=""

  # Parse command-specific flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --script) script_path="$2"; shift 2 ;;
      --verify) verify_only=true; shift ;;
      --force) force=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$host_alias" ] || { fail "Host alias required. Usage: strut <host> provision"; return 1; }

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

  # Directory model takes precedence unless an explicit --script overrides it.
  local scripts_dir=""
  if [ -z "$script_path" ]; then
    scripts_dir=$(_provision_find_scripts_dir "$host_alias") || scripts_dir=""
  fi

  if [ -n "$scripts_dir" ]; then
    _provision_run_dir_model "$host_alias" "$scripts_dir" "$user" "$host" "$port" "$ssh_opts" "$dry_run" "$force"
    return $?
  fi

  _provision_run_legacy_model "$host_alias" "$script_path" "$user" "$host" "$port" "$ssh_opts" "$dry_run" "$verify_only"
}
