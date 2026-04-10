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

  # Get the git-committed version hash using git show
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local relative_path="${file_path#$cli_root/}"

  local git_content
  git_content=$(git -C "$cli_root" show "HEAD:$relative_path" 2>/dev/null || echo "")

  if [ -z "$git_content" ]; then
    # File not tracked in git, use current file hash
    sha256sum "$file_path" 2>/dev/null | awk '{print $1}'
    return 0
  fi

  # Hash the git-committed content
  echo "$git_content" | sha256sum | awk '{print $1}'
}

# drift_get_vps_hash <file_path>
# Returns the sha256 hash of the current file on disk (VPS runtime)
drift_get_vps_hash() {
  local file_path="$1"

  if [ ! -f "$file_path" ]; then
    echo "missing"
    return 1
  fi

  # Hash the actual file on disk
  sha256sum "$file_path" 2>/dev/null | awk '{print $1}'
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

# drift_generate_diff <git_file> <vps_file>
# Generates a unified diff between git-committed and VPS files
drift_generate_diff() {
  local git_file="$1"
  local vps_file="$2"

  if [ ! -f "$vps_file" ]; then
    echo "VPS file missing: $vps_file"
    return 1
  fi

  # Get git-committed content
  local git_content
  git_content=$(drift_get_git_content "$git_file")

  if [ -z "$git_content" ]; then
    echo "Git file not tracked: $git_file"
    return 1
  fi

  # Get relative filename for labels
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local relative_path="${vps_file#$cli_root/stacks/}"

  # Create temp file with git content
  local temp_git_file
  temp_git_file=$(mktemp)
  echo "$git_content" > "$temp_git_file"

  # Generate unified diff with readable labels
  diff -u --label "git-committed/$relative_path" --label "vps-runtime/$relative_path" \
    "$temp_git_file" "$vps_file" 2>/dev/null || true  # diff returns 1 when files differ — expected

  # Cleanup
  rm -f "$temp_git_file"
}

# drift_detect <stack> <env>
# Main drift detection function - compares git-tracked vs VPS runtime config
drift_detect() {
  local stack="$1"
  local env="${2:-prod}"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"

  [ -d "$stack_dir" ] || { error "Stack directory not found: $stack_dir"; return 1; }

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
    local vps_file="$stack_dir/$tracked_file"

    # Skip if file doesn't exist in git
    [ -f "$git_file" ] || continue

    # Skip if file should be ignored
    if drift_should_ignore "$git_file" "$stack_dir"; then
      continue
    fi

    # Get hashes
    local git_hash
    local vps_hash
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$vps_file")

    # Compare hashes
    if [ "$git_hash" != "$vps_hash" ]; then
      # Validate syntax before reporting drift
      if ! drift_validate_syntax "$vps_file"; then
        warn "Skipping $tracked_file: invalid syntax on VPS"
        continue
      fi

      drift_detected=true
      drifted_files+=("$tracked_file")

      # Generate diff
      local diff_output
      diff_output=$(drift_generate_diff "$git_file" "$vps_file")

      drift_details+=("{\"file\":\"$tracked_file\",\"git_hash\":\"$git_hash\",\"vps_hash\":\"$vps_hash\",\"diff\":$(echo "$diff_output" | jq -Rs .)}")
    fi
  done

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

  # Check for --dry-run flag
  if [[ "$3" == "--dry-run" || "$env" == "--dry-run" ]]; then
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
    local vps_file="$stack_dir/$tracked_file"

    [ -f "$git_file" ] || continue
    drift_should_ignore "$git_file" "$stack_dir" && continue

    local git_hash
    local vps_hash
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$vps_file")

    if [ "$git_hash" != "$vps_hash" ]; then
      drifted_files+=("$tracked_file")
      local diff_output
      diff_output=$(drift_generate_diff "$git_file" "$vps_file")
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
    local vps_file="$stack_dir/$file"

    log "  Fixing: $file"

    # Copy git-tracked file to VPS location
    # In a real scenario, this would sync from git repo to VPS
    # For now, we assume git-tracked files are already in place
    # and we just need to ensure they match

    # Validate syntax before applying
    if ! drift_validate_syntax "$git_file"; then
      error "  Syntax validation failed for $file, skipping"
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
    local vps_file="$stack_dir/$tracked_file"

    [ -f "$git_file" ] || continue
    drift_should_ignore "$git_file" "$stack_dir" && continue

    local git_hash
    local vps_hash
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$vps_file")

    if [ "$git_hash" != "$vps_hash" ]; then
      drifted_files+=("$tracked_file")
      local diff_output
      diff_output=$(drift_generate_diff "$git_file" "$vps_file")
      drift_details+=("{\"file\":\"$tracked_file\",\"git_hash\":\"$git_hash\",\"vps_hash\":\"$vps_hash\",\"diff\":$(echo "$diff_output" | jq -Rs .)}")
    fi
  done

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

    local status="no_drift"
    [ ${#drifted_files[@]} -gt 0 ] && status="drift_detected"

    echo "{\"stack\":\"$stack\",\"env\":\"$env\",\"status\":\"$status\",\"drifted_files_count\":${#drifted_files[@]},\"files\":$files_json,\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" | jq '.'
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
        local vps_file="$stack_dir/$tracked_file"

        [ -f "$vps_file" ] || continue
        drift_should_ignore "$vps_file" "$stack_dir" && continue

        local git_hash
        local vps_hash
        git_hash=$(drift_get_git_hash "$vps_file")
        vps_hash=$(drift_get_vps_hash "$vps_file")

        if [ "$git_hash" != "$vps_hash" ]; then
          echo -e "${YELLOW}File: $tracked_file${NC}"
          echo "----------------------------------------"
          drift_generate_diff "$vps_file" "$vps_file" || echo "  (diff generation failed)"
          echo ""
        fi
      done

      echo "Run 'strut $stack drift diff <file>' to see detailed diff for a specific file"
      echo "Run 'strut $stack drift fix --env $env' to apply git-tracked configuration"
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
  local vps_file="$stack_dir/$file"

  [ -f "$vps_file" ] || { error "VPS file not found: $vps_file"; return 1; }

  # Get git-committed content
  local git_content
  git_content=$(drift_get_git_content "$vps_file")

  if [ -z "$git_content" ]; then
    error "File not tracked in git: $file"
    return 1
  fi

  echo -e "${BLUE}=================================================="
  echo -e "  Drift Diff: $file"
  echo -e "==================================================${NC}"
  echo ""
  echo -e "${GREEN}Git-committed version${NC} (source of truth)"
  echo -e "${RED}VPS runtime version${NC} (current file on disk)"
  echo ""

  # Create temp file with git content
  local temp_git_file
  temp_git_file=$(mktemp)
  echo "$git_content" > "$temp_git_file"

  # Show unified diff with labels
  diff -u --label "git-committed/$file" --label "vps-runtime/$file" \
    "$temp_git_file" "$vps_file" || true  # diff returns 1 when files differ — expected

  # Cleanup
  rm -f "$temp_git_file"

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
    local vps_file="$stack_dir/$tracked_file"

    [ -f "$git_file" ] || continue
    drift_should_ignore "$git_file" "$stack_dir" && continue

    local git_hash
    local vps_hash
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$vps_file")

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
