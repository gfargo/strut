#!/usr/bin/env bash
# ==================================================
# lib/drift.sh — Configuration drift detection
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Detects configuration drift between git-tracked files
# and VPS runtime configuration, with auto-fix capabilities.

# Source utils if not already sourced
set -euo pipefail

if [ -z "$RED" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/utils.sh"
fi
# diff_fetch_remote (SSH cat) — reused below so drift can compare against
# the file actually deployed on the VPS, not a second local copy of the
# same working-tree file (strut#182).
declare -F diff_fetch_remote >/dev/null || source "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/diff.sh"

# ── Configuration ─────────────────────────────────────────────────────────────

# drift_get_tracked_files
# Returns the list of files to track for drift detection (relative to stack directory)
# Dynamically includes the correct proxy config file based on REVERSE_PROXY
drift_get_tracked_files() {
  local base_files=(
    "docker-compose.yml"
    ".env.template"
    "backup.conf"
    "repos.conf"
    "volume.conf"
  )
  local proxy="${REVERSE_PROXY:-nginx}"
  case "$proxy" in
    nginx) base_files+=("nginx/nginx.conf") ;;
    caddy) base_files+=("caddy/Caddyfile") ;;
  esac
  echo "${base_files[@]}"
}

# ── Drift Detection Functions ─────────────────────────────────────────────────

# drift_get_git_hash <file_path>
# Returns the sha256 hash of the git-committed version of a file
drift_get_git_hash() {
  local file_path="$1"

  if [ ! -f "$file_path" ]; then
    echo "missing"
    return 1
  fi

  # Get the git-committed version using git show
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local relative_path="${file_path#$cli_root/}"

  # Check if the file is tracked in git
  if ! git -C "$cli_root" show "HEAD:$relative_path" &>/dev/null; then
    # File not tracked in git — hash via a captured variable (see below)
    # rather than `sha256sum file` directly, so this stays consistent with
    # the tracked-file branch's normalization.
    local untracked_content
    untracked_content=$(cat "$file_path" 2>/dev/null)
    printf '%s' "$untracked_content" | sha256sum | awk '{print $1}'
    return 0
  fi

  # Hash the git-committed content via a captured variable (command
  # substitution strips a trailing newline) rather than piping raw bytes.
  # This must match drift_get_vps_hash's normalization exactly: a remote
  # fetch over SSH is ALSO captured via command substitution (diff_fetch_remote),
  # which strips a trailing newline the same way — comparing a raw-byte git
  # hash against a substitution-stripped remote hash would falsely flag
  # drift on every file that simply ends in a newline (nearly all of them).
  # A lone trailing newline is treated as insignificant everywhere in drift
  # comparison, not just for the local case the July 2026 fix covered.
  local git_content
  git_content=$(git -C "$cli_root" show "HEAD:$relative_path" 2>/dev/null)
  printf '%s' "$git_content" | sha256sum | awk '{print $1}'
}

# drift_get_vps_hash <stack> <tracked_file> <stack_dir>
#
# Returns the sha256 hash of the file as actually DEPLOYED. When VPS_HOST
# is configured (loaded by validate_env_file before any drift_* command
# runs — see cmd_drift.sh), fetches the real file from the VPS deploy dir
# over SSH and hashes THAT — comparing against what's actually running,
# not a second local copy of the same working-tree file. Previously
# git_file and vps_file were the same local path, so drift was blind to
# real VPS-side changes and could report CLEAN while `strut diff` showed
# pending changes (strut#182). Falls back to the local working-tree file
# for local-only stacks (no VPS_HOST) or when the deploy dir can't be
# resolved.
#
# Echoes one of: a sha256 hash, "missing" (file absent, local or remote),
# or "unreachable" (VPS_HOST set but SSH couldn't connect — the caller
# must skip this file rather than treat it as drift, since "we couldn't
# check" and "it changed" are different things).
# Return code: 0 = hash, 1 = missing, 2 = unreachable.
drift_get_vps_hash() {
  local stack="$1"
  local tracked_file="$2"
  local stack_dir="$3"
  local local_file="$stack_dir/$tracked_file"

  if [ -n "${VPS_HOST:-}" ] && declare -F resolve_deploy_dir >/dev/null 2>&1; then
    local deploy_dir
    deploy_dir=$(resolve_deploy_dir 2>/dev/null) || deploy_dir=""
    if [ -n "$deploy_dir" ]; then
      local remote_path="$deploy_dir/stacks/$stack/$tracked_file"
      local remote_content rc=0
      remote_content=$(diff_fetch_remote "$remote_path") || rc=$?
      if [ "${rc:-0}" -eq 2 ]; then
        echo "unreachable"
        return 2
      fi
      if [ -z "$remote_content" ]; then
        echo "missing"
        return 1
      fi
      printf '%s' "$remote_content" | sha256sum | awk '{print $1}'
      return 0
    fi
  fi

  # Local-only stack, or deploy dir couldn't be resolved. Captured via a
  # variable (strips a trailing newline) rather than `sha256sum file`
  # directly, matching drift_get_git_hash's normalization exactly.
  if [ ! -f "$local_file" ]; then
    echo "missing"
    return 1
  fi
  local local_content
  local_content=$(cat "$local_file" 2>/dev/null)
  printf '%s' "$local_content" | sha256sum | awk '{print $1}'
}

# drift_get_git_content <file_path>
# Returns the git-committed content of a file (for diff generation)
drift_get_git_content() {
  local file_path="$1"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local relative_path="${file_path#$cli_root/}"

  git -C "$cli_root" show "HEAD:$relative_path" 2>/dev/null || echo ""
}

# drift_load_ignore_patterns <stack_dir>
# Loads .drift-ignore patterns into an array
drift_load_ignore_patterns() {
  local stack_dir="$1"
  local ignore_file="$stack_dir/.drift-ignore"

  DRIFT_IGNORE_PATTERNS=()

  if [ -f "$ignore_file" ]; then
    while IFS= read -r pattern; do
      # Skip empty lines and comments
      [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue
      DRIFT_IGNORE_PATTERNS+=("$pattern")
    done < "$ignore_file"
  fi
}

# drift_should_ignore <file_path> <stack_dir>
# Returns 0 if file should be ignored, 1 otherwise
drift_should_ignore() {
  local file_path="$1"
  local stack_dir="$2"
  local relative_path="${file_path#$stack_dir/}"

  drift_load_ignore_patterns "$stack_dir"

  for pattern in "${DRIFT_IGNORE_PATTERNS[@]}"; do
    # Intentional glob match — $pattern contains wildcards like *.bak
    # shellcheck disable=SC2053
    if [[ "$relative_path" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

# drift_validate_syntax <file_path>
# Validates configuration file syntax before reporting drift
drift_validate_syntax() {
  local file_path="$1"
  local filename
  filename=$(basename "$file_path")

  case "$filename" in
    docker-compose.yml|docker-compose.*.yml)
      # Validate docker-compose syntax
      if command -v docker &>/dev/null; then
        docker compose -f "$file_path" config >/dev/null 2>&1
        return $?
      fi
      ;;
    nginx.conf)
      # Validate nginx config if nginx is available
      if command -v nginx &>/dev/null; then
        nginx -t -c "$file_path" >/dev/null 2>&1
        return $?
      fi
      ;;
    Caddyfile)
      # Validate Caddy config if caddy is available
      if command -v caddy &>/dev/null; then
        caddy validate --config "$file_path" >/dev/null 2>&1
        return $?
      fi
      ;;
    *.json)
      # Validate JSON syntax
      if command -v jq &>/dev/null; then
        jq empty "$file_path" >/dev/null 2>&1
        return $?
      fi
      ;;
  esac

  # If no specific validation, assume valid
  return 0
}

# drift_generate_diff <stack> <tracked_file> <stack_dir>
#
# Generates a unified diff between git-committed and deployed content.
# Deployed content is the real VPS file over SSH when VPS_HOST is set
# (matching drift_get_vps_hash's resolution), else the local working-tree
# copy for local-only stacks.
drift_generate_diff() {
  local stack="$1"
  local tracked_file="$2"
  local stack_dir="$3"
  local git_file="$stack_dir/$tracked_file"

  # Get git-committed content
  local git_content
  git_content=$(drift_get_git_content "$git_file")

  if [ -z "$git_content" ]; then
    echo "Git file not tracked: $tracked_file"
    return 1
  fi

  # Resolve deployed content the same way drift_get_vps_hash does.
  local vps_content=""
  local using_remote=false
  if [ -n "${VPS_HOST:-}" ] && declare -F resolve_deploy_dir >/dev/null 2>&1; then
    local deploy_dir
    deploy_dir=$(resolve_deploy_dir 2>/dev/null) || deploy_dir=""
    if [ -n "$deploy_dir" ]; then
      using_remote=true
      vps_content=$(diff_fetch_remote "$deploy_dir/stacks/$stack/$tracked_file") || {
        echo "VPS unreachable: could not fetch $tracked_file"
        return 1
      }
    fi
  fi
  if ! $using_remote; then
    local local_file="$stack_dir/$tracked_file"
    [ -f "$local_file" ] || { echo "VPS file missing: $tracked_file"; return 1; }
    vps_content=$(cat "$local_file")
  fi
  [ -n "$vps_content" ] || { echo "VPS file missing: $tracked_file"; return 1; }

  # Create temp files for a real diff(1) invocation
  local temp_git_file temp_vps_file
  temp_git_file=$(mktemp)
  temp_vps_file=$(mktemp)
  printf '%s' "$git_content" > "$temp_git_file"
  printf '%s' "$vps_content" > "$temp_vps_file"

  local label="local-workdir"
  $using_remote && label="vps-runtime"

  # Generate unified diff with readable labels
  diff -u --label "git-committed/$tracked_file" --label "$label/$tracked_file" \
    "$temp_git_file" "$temp_vps_file" 2>/dev/null || true  # diff returns 1 when files differ — expected

  rm -f "$temp_git_file" "$temp_vps_file"
}

# _drift_check_timers <stack> <stack_dir>
#
# Lazily sources lib/timers.sh (so a stack with no timers.conf never pulls
# it in) and runs timers_drift, echoing its \x1f-delimited "unit\x1freason"
# records straight through — see timers_drift for reason values
# (missing/modified/orphaned). Host-side only: a hand-edited or missing
# systemd unit can only be detected on the host the timer actually runs
# on, so — like timers_install/timers_list — this never fetches anything
# over SSH and no-ops when there's no timers.conf or no systemctl.
_drift_check_timers() {
  local stack="$1"
  local stack_dir="$2"
  declare -F timers_drift >/dev/null || source "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/timers.sh"
  timers_drift "$stack" "$stack_dir"
}

# drift_detect <stack> <env>
# Main drift detection function - compares git-tracked vs VPS runtime config
drift_detect() {
  local stack="$1"
  local env="${2:-prod}"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"

  if [ ! -d "$stack_dir" ]; then
    log "Stack directory not found: $stack_dir (config-only stack — skipping drift)"
    return 0
  fi

  log "Detecting configuration drift for stack: $stack (env: $env)"

  local drift_detected=false
  local drifted_files=()
  local drift_details=()

  # Load ignore patterns
  drift_load_ignore_patterns "$stack_dir"

  # Get tracked files dynamically based on REVERSE_PROXY
  local -a tracked_files
  IFS=' ' read -ra tracked_files <<< "$(drift_get_tracked_files)"

  # Check each tracked file
  for tracked_file in "${tracked_files[@]}"; do
    local git_file="$stack_dir/$tracked_file"

    # Skip if file doesn't exist in git
    [ -f "$git_file" ] || continue

    # Skip if file should be ignored
    if drift_should_ignore "$git_file" "$stack_dir"; then
      continue
    fi

    # Get hashes. drift_get_vps_hash fetches the real deployed file over
    # SSH when VPS_HOST is set, falling back to the local working-tree
    # copy for local-only stacks (strut#182).
    local git_hash
    local vps_hash
    local vps_rc=0
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$stack" "$tracked_file" "$stack_dir") || vps_rc=$?
    if [ "$vps_rc" -eq 2 ]; then
      warn "Skipping $tracked_file: VPS unreachable — could not verify"
      continue
    fi

    # Compare hashes
    if [ "$git_hash" != "$vps_hash" ]; then
      # Validate syntax before reporting drift (local-only stacks only —
      # the remote-fetched case would need a second SSH round-trip to
      # write the content somewhere lintable; not worth it for a
      # best-effort pre-report sanity check).
      if [ -z "${VPS_HOST:-}" ] && ! drift_validate_syntax "$stack_dir/$tracked_file"; then
        warn "Skipping $tracked_file: invalid syntax on disk"
        continue
      fi

      drift_detected=true
      drifted_files+=("$tracked_file")

      # Generate diff
      local diff_output
      diff_output=$(drift_generate_diff "$stack" "$tracked_file" "$stack_dir")

      drift_details+=("{\"file\":\"$tracked_file\",\"git_hash\":\"$git_hash\",\"vps_hash\":\"$vps_hash\",\"diff\":$(echo "$diff_output" | jq -Rs .)}")
    fi
  done

  # Check if this checkout is behind origin — a host running N commits behind is
  # considered drifted even when the specific stack files happen to match HEAD.
  local branch="${DEFAULT_BRANCH:-main}"
  if git -C "$cli_root" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    local _behind=0
    _behind=$(git -C "$cli_root" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)
    if [ "${_behind:-0}" -gt 0 ]; then
      drift_detected=true
      drifted_files+=("<git: $_behind commit(s) behind origin/$branch>")
      drift_details+=("{\"file\":\"<origin/$branch>\",\"behind\":$_behind,\"git_hash\":\"\",\"vps_hash\":\"\",\"diff\":\"\"}")
    fi
  fi

  # Check declarative timer drift — hand-edited or missing systemd units
  # for this stack's timers.conf (strut#449).
  local timer_drift
  timer_drift="$(_drift_check_timers "$stack" "$stack_dir")"
  if [ -n "$timer_drift" ]; then
    local t_unit t_reason
    while IFS=$'\x1f' read -r t_unit t_reason; do
      [ -n "$t_unit" ] || continue
      drift_detected=true
      drifted_files+=("<timer: $t_unit ($t_reason)>")
      drift_details+=("{\"file\":\"<timer:$t_unit>\",\"reason\":\"$t_reason\",\"git_hash\":\"\",\"vps_hash\":\"\",\"diff\":\"\"}")
    done <<< "$timer_drift"
  fi

  # Report results
  if $drift_detected; then
    warn "Configuration drift detected!"
    echo ""
    echo "Drifted files:"
    for file in "${drifted_files[@]}"; do
      echo "  - $file"
    done

    # Store drift event
    drift_store_event "$stack" "$env" "${drift_details[@]}"

    return 1
  else
    ok "No configuration drift detected"
    return 0
  fi
}

# drift_store_event <stack> <env> <drift_details...>
# Stores a drift detection event in the drift history
drift_store_event() {
  local stack="$1"
  local env="$2"
  shift 2
  local drift_details=("$@")

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local drift_history_dir="$cli_root/stacks/$stack/drift-history"
  mkdir -p "$drift_history_dir"

  local timestamp
  timestamp=$(date -u +"%Y%m%d-%H%M%S")
  local drift_file="$drift_history_dir/${timestamp}.json"

  # Build JSON array of drift details
  local files_json="["
  local first=true
  for detail in "${drift_details[@]}"; do
    if $first; then
      first=false
    else
      files_json+=","
    fi
    files_json+="$detail"
  done
  files_json+="]"

  # Create drift event JSON
  cat > "$drift_file" <<EOF
{
  "drift_id": "drift-${timestamp}",
  "stack": "$stack",
  "env": "$env",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "detected",
  "files_drifted": $files_json,
  "resolution": null
}
EOF

  log "Drift event stored: $drift_file"
  return 0
}

# drift_update_event_resolution <stack> <drift_id> <method> <status>
# Updates the resolution section of a drift event
drift_update_event_resolution() {
  local stack="$1"
  local drift_id="$2"
  local method="$3"
  local status="$4"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local drift_file="$cli_root/stacks/$stack/drift-history/${drift_id#drift-}.json"

  [ -f "$drift_file" ] || { error "Drift event not found: $drift_file"; return 1; }

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Update resolution using jq if available
  if command -v jq &>/dev/null; then
    local temp_file
    temp_file=$(mktemp)
    jq ".resolution = {\"method\":\"$method\",\"timestamp\":\"$timestamp\",\"status\":\"$status\"}" \
      "$drift_file" > "$temp_file" && mv "$temp_file" "$drift_file"
    ok "Drift event resolution updated"
  else
    warn "jq not found, cannot update drift event resolution"
    return 1
  fi

  return 0
}

# drift_fix <stack> <env> [--dry-run]
# Fixes configuration drift by applying git-tracked configuration
drift_fix() {
  local stack="$1"
  local env="${2:-prod}"
  local dry_run=false

  # Check for --dry-run flag (${3:-} — $3 is unbound when called with 2 args,
  # which under `set -u` would abort the whole process, not just this function).
  if [[ "${3:-}" == "--dry-run" || "$env" == "--dry-run" ]]; then
    dry_run=true
    [ "$env" == "--dry-run" ] && env="prod"
  fi

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"

  [ -d "$stack_dir" ] || { error "Stack directory not found: $stack_dir"; return 1; }

  # Source alerts module
  if [ -f "$cli_root/lib/drift/alerts.sh" ]; then
    source "$cli_root/lib/drift/alerts.sh"
  fi

  # First detect drift
  log "Checking for configuration drift..."
  local drifted_files=()
  local drift_details=()

  drift_load_ignore_patterns "$stack_dir"

  # Get tracked files dynamically based on REVERSE_PROXY
  local -a tracked_files
  IFS=' ' read -ra tracked_files <<< "$(drift_get_tracked_files)"

  for tracked_file in "${tracked_files[@]}"; do
    local git_file="$stack_dir/$tracked_file"

    [ -f "$git_file" ] || continue
    drift_should_ignore "$git_file" "$stack_dir" && continue

    local git_hash
    local vps_hash
    local vps_rc=0
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$stack" "$tracked_file" "$stack_dir") || vps_rc=$?
    if [ "$vps_rc" -eq 2 ]; then
      warn "Skipping $tracked_file: VPS unreachable — could not verify"
      continue
    fi

    if [ "$git_hash" != "$vps_hash" ]; then
      drifted_files+=("$tracked_file")
      drift_details+=("{\"file\":\"$tracked_file\",\"git_hash\":\"$git_hash\",\"vps_hash\":\"$vps_hash\"}")
    fi
  done

  if [ ${#drifted_files[@]} -eq 0 ]; then
    ok "No drift detected, nothing to fix"
    return 0
  fi

  if $dry_run; then
    log "Dry-run mode: would fix the following files:"
    for file in "${drifted_files[@]}"; do
      echo "  - $file"
    done
    return 0
  fi

  # Create backup before fixing
  log "Creating backup of current VPS configuration..."
  local backup_dir="$stack_dir/drift-backups"
  mkdir -p "$backup_dir"
  local backup_timestamp
  backup_timestamp=$(date -u +"%Y%m%d-%H%M%S")
  local backup_file="$backup_dir/pre-fix-${backup_timestamp}.tar.gz"

  tar -czf "$backup_file" -C "$stack_dir" "${drifted_files[@]}" 2>/dev/null || {
    error "Failed to create backup"
    alert_drift_fix_failed "$stack" "$env" "Failed to create backup"
    return 1
  }
  ok "Backup created: $backup_file"

  # Apply git-tracked configuration
  log "Applying git-tracked configuration..."
  local fix_failed=false

  for file in "${drifted_files[@]}"; do
    local git_file="$stack_dir/$file"
    local relative_path="${git_file#"$cli_root"/}"

    log "  Restoring from git HEAD: $file"

    # Actually restore the tracked version into the working tree. This loop
    # previously only ran a syntax check and changed NOTHING, yet reported
    # "fixed successfully" — real remediation is `git checkout HEAD -- <path>`.
    # (Only git-tracked files reach here: untracked files hash-match themselves
    # in detection and never register as drift.)
    if ! git -C "$cli_root" checkout HEAD -- "$relative_path" 2>/dev/null; then
      error "  Failed to restore $file from git HEAD (is it committed?)"
      fix_failed=true
      continue
    fi

    # Validate syntax of the now-restored file
    if ! drift_validate_syntax "$git_file"; then
      error "  Syntax validation failed for $file after restore"
      fix_failed=true
      continue
    fi
  done

  if $fix_failed; then
    error "Some files failed to fix"
    alert_drift_fix_failed "$stack" "$env" "Syntax validation failed for some files"
    return 1
  fi

  # Run health checks after fix
  log "Running health checks..."
  if [ -f "$cli_root/lib/health.sh" ]; then
    source "$cli_root/lib/health.sh"

    # Determine compose command
    local compose_cmd="docker compose"
    local compose_file="$stack_dir/docker-compose.yml"

    if ! health_check_docker >/dev/null 2>&1; then
      warn "Health check failed after drift fix"

      # Rollback configuration
      log "Rolling back configuration..."
      tar -xzf "$backup_file" -C "$stack_dir" 2>/dev/null || {
        error "Failed to rollback configuration!"
        alert_drift_fix_failed "$stack" "$env" "Health check failed and rollback failed"
        return 1
      }

      ok "Configuration rolled back"
      alert_drift_fix_failed "$stack" "$env" "Health check failed after fix, configuration rolled back"
      return 1
    fi
  fi

  ok "Configuration drift fixed successfully"
  if [ -n "${VPS_HOST:-}" ]; then
    log "This restored the local git-tracked source — run 'strut $stack deploy --env $env' or 'release' to push it to the VPS."
  fi

  # Update drift event resolution
  local latest_drift_file
  latest_drift_file=$(ls -t "$stack_dir/drift-history"/*.json 2>/dev/null | head -1)
  if [ -n "$latest_drift_file" ]; then
    local drift_id
    drift_id=$(basename "$latest_drift_file" .json)
    drift_update_event_resolution "$stack" "drift-$drift_id" "manual" "success"
  fi

  # Send success alert
  alert_drift_fixed "$stack" "$env" "${#drifted_files[@]}" "manual"

  return 0
}

# drift_report <stack> <env> [--json]
# Generates a drift detection report
drift_report() {
  local stack="$1"
  local env="${2:-prod}"
  local json_output=false

  [[ "$3" == "--json" || "$env" == "--json" ]] && json_output=true
  [ "$env" == "--json" ] && env="prod"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"

  [ -d "$stack_dir" ] || { error "Stack directory not found: $stack_dir"; return 1; }

  # Detect current drift
  local drifted_files=()
  local drift_details=()

  drift_load_ignore_patterns "$stack_dir"

  # Get tracked files dynamically based on REVERSE_PROXY
  local -a tracked_files
  IFS=' ' read -ra tracked_files <<< "$(drift_get_tracked_files)"

  for tracked_file in "${tracked_files[@]}"; do
    local git_file="$stack_dir/$tracked_file"

    [ -f "$git_file" ] || continue
    drift_should_ignore "$git_file" "$stack_dir" && continue

    local git_hash
    local vps_hash
    local vps_rc=0
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$stack" "$tracked_file" "$stack_dir") || vps_rc=$?
    [ "$vps_rc" -eq 2 ] && continue  # unreachable — omit from the report rather than false-flag it

    if [ "$git_hash" != "$vps_hash" ]; then
      drifted_files+=("$tracked_file")
      local diff_output
      diff_output=$(drift_generate_diff "$stack" "$tracked_file" "$stack_dir")
      drift_details+=("{\"file\":\"$tracked_file\",\"git_hash\":\"$git_hash\",\"vps_hash\":\"$vps_hash\",\"diff\":$(echo "$diff_output" | jq -Rs .)}")
    fi
  done

  # Declarative timer drift — hand-edited/missing/orphaned systemd units
  # for this stack's timers.conf (strut#449). See _drift_check_timers.
  local timer_drift
  timer_drift="$(_drift_check_timers "$stack" "$stack_dir")"
  local timer_units=() timer_reasons=()
  if [ -n "$timer_drift" ]; then
    local t_unit t_reason
    while IFS=$'\x1f' read -r t_unit t_reason; do
      [ -n "$t_unit" ] || continue
      timer_units+=("$t_unit")
      timer_reasons+=("$t_reason")
    done <<< "$timer_drift"
  fi

  if $json_output; then
    # Build JSON report
    local files_json="["
    local first=true
    for detail in "${drift_details[@]}"; do
      if $first; then
        first=false
      else
        files_json+=","
      fi
      files_json+="$detail"
    done
    files_json+="]"

    local timers_json="["
    first=true
    local i
    for i in "${!timer_units[@]}"; do
      if $first; then
        first=false
      else
        timers_json+=","
      fi
      timers_json+="{\"unit\":\"${timer_units[$i]}\",\"reason\":\"${timer_reasons[$i]}\"}"
    done
    timers_json+="]"

    local status="no_drift"
    { [ ${#drifted_files[@]} -gt 0 ] || [ ${#timer_units[@]} -gt 0 ]; } && status="drift_detected"

    echo "{\"stack\":\"$stack\",\"env\":\"$env\",\"status\":\"$status\",\"drifted_files_count\":${#drifted_files[@]},\"files\":$files_json,\"timers_drift_count\":${#timer_units[@]},\"timers\":$timers_json,\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" | jq '.'
  else
    # Human-readable report with diffs
    echo -e "${BLUE}=================================================="
    echo -e "  Drift Detection Report: $stack"
    echo -e "==================================================${NC}"
    echo ""

    if [ ${#drifted_files[@]} -eq 0 ]; then
      ok "No configuration drift detected"
    else
      warn "Configuration drift detected in ${#drifted_files[@]} file(s)"
      echo ""

      # Show each drifted file with its diff
      for tracked_file in "${tracked_files[@]}"; do
        local git_file="$stack_dir/$tracked_file"

        [ -f "$git_file" ] || continue
        drift_should_ignore "$git_file" "$stack_dir" && continue

        local git_hash
        local vps_hash
        local vps_rc=0
        git_hash=$(drift_get_git_hash "$git_file")
        vps_hash=$(drift_get_vps_hash "$stack" "$tracked_file" "$stack_dir") || vps_rc=$?
        [ "$vps_rc" -eq 2 ] && continue

        if [ "$git_hash" != "$vps_hash" ]; then
          echo -e "${YELLOW}File: $tracked_file${NC}"
          echo "----------------------------------------"
          # Previously compared vps_file against itself here — always an
          # empty diff even when the hashes above disagreed.
          drift_generate_diff "$stack" "$tracked_file" "$stack_dir" || echo "  (diff generation failed)"
          echo ""
        fi
      done

      echo "Run 'strut $stack drift diff <file>' to see detailed diff for a specific file"
      echo "Run 'strut $stack drift fix --env $env' to apply git-tracked configuration"
    fi

    if [ ${#timer_units[@]} -gt 0 ]; then
      echo ""
      warn "Timer drift detected in ${#timer_units[@]} unit(s)"
      echo ""
      local i
      for i in "${!timer_units[@]}"; do
        echo -e "${YELLOW}Timer: ${timer_units[$i]}${NC} (${timer_reasons[$i]})"
      done
      echo ""
      echo "Run 'strut $stack timers install' to re-render and reinstall managed timer units"
    fi
  fi

  return 0
}

# drift_diff <stack> <file>
# Shows detailed diff for a specific file
drift_diff() {
  local stack="$1"
  local file="$2"

  [ -z "$file" ] && { error "Usage: drift diff <stack> <file>"; return 1; }

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  local git_file="$stack_dir/$file"

  [ -f "$git_file" ] || { error "File not found: $git_file"; return 1; }

  # Get git-committed content (just to give a clear "not tracked" error
  # before printing headers — drift_generate_diff re-fetches this itself).
  local git_content
  git_content=$(drift_get_git_content "$git_file")
  if [ -z "$git_content" ]; then
    error "File not tracked in git: $file"
    return 1
  fi

  echo -e "${BLUE}=================================================="
  echo -e "  Drift Diff: $file"
  echo -e "==================================================${NC}"
  echo ""
  echo -e "${GREEN}Git-committed version${NC} (source of truth)"
  # `drift diff` isn't routed through validate_env_file (cmd_drift.sh), so
  # VPS_HOST is normally unset here and this shows the local working-tree
  # copy — same as drift_generate_diff's fallback for local-only stacks.
  if [ -n "${VPS_HOST:-}" ]; then
    echo -e "${RED}VPS runtime version${NC} (fetched over SSH)"
  else
    echo -e "${RED}Local working-tree version${NC} (current file on disk)"
  fi
  echo ""

  drift_generate_diff "$stack" "$file" "$stack_dir" || echo "  (diff generation failed)"

  return 0
}

# drift_history <stack> [--limit N]
# Shows drift detection history
drift_history() {
  local stack="$1"
  local limit=10

  # Parse limit flag
  if [[ "$2" == "--limit" && -n "$3" ]]; then
    limit="$3"
  fi

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local drift_history_dir="$cli_root/stacks/$stack/drift-history"

  if [ ! -d "$drift_history_dir" ]; then
    log "No drift history found for stack: $stack"
    return 0
  fi

  echo -e "${BLUE}=================================================="
  echo -e "  Drift History: $stack"
  echo -e "==================================================${NC}"
  echo ""

  local count=0
  # List drift events in reverse chronological order
  local drift_files=()
  while IFS= read -r -d '' f; do
    drift_files+=("$f")
  done < <(find "$drift_history_dir" -maxdepth 1 -name '*.json' -print0 2>/dev/null | sort -z -r)

  for drift_file in "${drift_files[@]}"; do
    [ $count -ge $limit ] && break

    if command -v jq &>/dev/null; then
      local drift_id
      local timestamp
      local status
      local files_count
      local resolution_method

      drift_id=$(jq -r '.drift_id' "$drift_file")
      timestamp=$(jq -r '.timestamp' "$drift_file")
      status=$(jq -r '.status' "$drift_file")
      files_count=$(jq -r '.files_drifted | length' "$drift_file")
      resolution_method=$(jq -r '.resolution.method // "unresolved"' "$drift_file")

      echo "[$timestamp] $drift_id"
      echo "  Status: $status"
      echo "  Files affected: $files_count"
      echo "  Resolution: $resolution_method"
      echo ""
    else
      echo "$(basename "$drift_file")"
    fi

    count=$((count + 1))
  done

  if [ $count -eq 0 ]; then
    log "No drift events found"
  fi

  return 0
}

# drift_monitor <stack> <env> [--auto-fix]
# Monitoring function for cron job - detects drift and sends alerts
drift_monitor() {
  local stack="$1"
  local env="${2:-prod}"
  local auto_fix=false

  # Check for --auto-fix flag
  if [[ "$3" == "--auto-fix" || "$env" == "--auto-fix" ]]; then
    auto_fix=true
    [ "$env" == "--auto-fix" ] && env="prod"
  fi

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"

  # Source alerts module
  if [ -f "$cli_root/lib/drift/alerts.sh" ]; then
    source "$cli_root/lib/drift/alerts.sh"
  fi

  # Detect drift
  local drifted_files=()
  drift_load_ignore_patterns "$stack_dir"

  # Get tracked files dynamically based on REVERSE_PROXY
  local -a tracked_files
  IFS=' ' read -ra tracked_files <<< "$(drift_get_tracked_files)"

  for tracked_file in "${tracked_files[@]}"; do
    local git_file="$stack_dir/$tracked_file"

    [ -f "$git_file" ] || continue
    drift_should_ignore "$git_file" "$stack_dir" && continue

    local git_hash
    local vps_hash
    local vps_rc=0
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$stack" "$tracked_file" "$stack_dir") || vps_rc=$?
    [ "$vps_rc" -eq 2 ] && continue  # unreachable — don't page on a network blip

    if [ "$git_hash" != "$vps_hash" ]; then
      drifted_files+=("$tracked_file")
    fi
  done

  # If drift detected
  if [ ${#drifted_files[@]} -gt 0 ]; then
    local files_list=""
    for file in "${drifted_files[@]}"; do
      files_list+="  - $file\n"
    done

    # Try auto-fix if enabled
    if $auto_fix; then
      log "Drift detected, attempting auto-fix..."
      if drift_fix "$stack" "$env"; then
        ok "Auto-fix successful"
        alert_drift_fixed "$stack" "$env" "${#drifted_files[@]}" "auto"
        return 0
      else
        error "Auto-fix failed"
        alert_drift_fix_failed "$stack" "$env" "Auto-fix execution failed"
        return 1
      fi
    else
      # Just send alert
      alert_drift_detected "$stack" "$env" "${#drifted_files[@]}" "$files_list"
      return 1
    fi
  fi

  return 0
}
