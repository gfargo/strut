#!/usr/bin/env bash
# ==================================================
# lib/rollback.sh — Deploy rollback snapshot management
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Provides:
#   rollback_save_snapshot    — capture current container image digests
#   rollback_restore_snapshot — restore from a snapshot
#   rollback_list_snapshots   — list available rollback points
#   rollback_enforce_retention — prune old snapshots

set -euo pipefail

# ── Snapshot directory ────────────────────────────────────────────────────────

# _rollback_dir <stack>
# Returns the rollback snapshot directory for a stack
_rollback_dir() {
  local stack="$1"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  echo "$cli_root/stacks/$stack/.rollback"
}

# ── Save snapshot ─────────────────────────────────────────────────────────────

# rollback_save_snapshot <stack> <compose_cmd> <env_name>
# Captures current container image digests before a deploy.
# Returns 0 on success, 1 if no running containers found.
rollback_save_snapshot() {
  local stack="$1"
  local compose_cmd="$2"
  local env_name="$3"

  local rollback_dir
  rollback_dir=$(_rollback_dir "$stack")
  mkdir -p "$rollback_dir"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local filename
  filename=$(date -u +"%Y%m%d-%H%M%S")
  local snapshot_file="$rollback_dir/${filename}.json"

  # Get running service images via compose
  local services_json="{"
  local first=true
  local service_count=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local service image
    service=$(echo "$line" | awk '{print $1}')
    image=$(echo "$line" | awk '{print $2}')
    [ -z "$service" ] || [ -z "$image" ] && continue

    if $first; then
      first=false
    else
      services_json+=","
    fi
    services_json+="\"$service\":{\"image\":\"$image\"}"
    service_count=$((service_count + 1))
  done < <($compose_cmd ps --format '{{.Service}} {{.Image}}' 2>/dev/null || true)

  services_json+="}"

  if [ "$service_count" -eq 0 ]; then
    # No running containers — still save an empty snapshot for the record
    services_json="{}"
  fi

  # Write snapshot
  cat > "$snapshot_file" <<EOF
{
  "timestamp": "$timestamp",
  "stack": "$stack",
  "env": "$env_name",
  "service_count": $service_count,
  "services": $services_json
}
EOF

  log "Rollback snapshot saved: $filename ($service_count services)"
  rollback_enforce_retention "$stack"
  return 0
}

# ── Restore snapshot ──────────────────────────────────────────────────────────

# rollback_get_latest_snapshot <stack>
# Echoes the path to the most recent snapshot file, or empty if none.
rollback_get_latest_snapshot() {
  local stack="$1"
  local rollback_dir
  rollback_dir=$(_rollback_dir "$stack")

  [ -d "$rollback_dir" ] || { echo ""; return 0; }
  ls -t "$rollback_dir"/*.json 2>/dev/null | head -1 || echo ""
}

# rollback_restore_snapshot <stack> <compose_cmd> <snapshot_file>
# Restores containers to the image versions in the snapshot.
rollback_restore_snapshot() {
  local stack="$1"
  local compose_cmd="$2"
  local snapshot_file="$3"

  [ -f "$snapshot_file" ] || { error "Snapshot not found: $snapshot_file"; return 1; }

  if ! command -v jq &>/dev/null; then
    fail "jq is required for rollback (install with: brew install jq)"
  fi

  local timestamp
  timestamp=$(jq -r '.timestamp' "$snapshot_file")
  local service_count
  service_count=$(jq -r '.service_count' "$snapshot_file")

  log "Restoring from snapshot: $(basename "$snapshot_file" .json)"
  log "  Timestamp: $timestamp"
  log "  Services: $service_count"

  # Pull the specific image versions from the snapshot
  local services
  services=$(jq -r '.services | to_entries[] | "\(.key) \(.value.image)"' "$snapshot_file")

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local service image
    service=$(echo "$line" | awk '{print $1}')
    image=$(echo "$line" | awk '{print $2}')

    log "  Pulling $service → $image"
    docker pull "$image" 2>/dev/null || warn "Failed to pull $image (may have been removed from registry)"
  done <<< "$services"

  # Stop current containers
  log "Stopping current containers..."
  $compose_cmd down --remove-orphans 2>/dev/null || true

  # Start with the restored images
  log "Starting services with restored images..."
  $compose_cmd up -d --remove-orphans

  ok "Rollback complete"
  return 0
}

# ── List snapshots ────────────────────────────────────────────────────────────

# rollback_list_snapshots <stack>
# Lists available rollback points with metadata.
rollback_list_snapshots() {
  local stack="$1"
  local rollback_dir
  rollback_dir=$(_rollback_dir "$stack")

  if [ ! -d "$rollback_dir" ] || [ -z "$(ls "$rollback_dir"/*.json 2>/dev/null)" ]; then
    warn "No rollback snapshots found for stack: $stack"
    return 0
  fi

  echo ""
  echo -e "${BLUE}Available rollback points for $stack:${NC}"
  echo ""

  local now
  now=$(date +%s)

  for snapshot_file in "$rollback_dir"/*.json; do
    [ -f "$snapshot_file" ] || continue
    local filename
    filename=$(basename "$snapshot_file" .json)

    if command -v jq &>/dev/null; then
      local timestamp service_count env_name
      timestamp=$(jq -r '.timestamp' "$snapshot_file")
      service_count=$(jq -r '.service_count' "$snapshot_file")
      env_name=$(jq -r '.env' "$snapshot_file")

      # Calculate age
      local snap_epoch
      snap_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || date -d "$timestamp" +%s 2>/dev/null || echo "0")
      local age_seconds=$((now - snap_epoch))
      local age_str=""
      if [ "$age_seconds" -lt 3600 ]; then
        age_str="$((age_seconds / 60))m ago"
      elif [ "$age_seconds" -lt 86400 ]; then
        age_str="$((age_seconds / 3600))h ago"
      else
        age_str="$((age_seconds / 86400))d ago"
      fi

      echo "  $filename  ($service_count services, env: $env_name, $age_str)"
    else
      echo "  $filename"
    fi
  done
  echo ""
}

# ── Retention ─────────────────────────────────────────────────────────────────

# rollback_enforce_retention <stack>
# Keeps only the last N snapshots (default: 5, configurable via ROLLBACK_RETENTION)
rollback_enforce_retention() {
  local stack="$1"
  local retention="${ROLLBACK_RETENTION:-5}"
  local rollback_dir
  rollback_dir=$(_rollback_dir "$stack")

  [ -d "$rollback_dir" ] || return 0

  local snapshots=()
  while IFS= read -r f; do
    [ -f "$f" ] && snapshots+=("$f")
  done < <(ls -t "$rollback_dir"/*.json 2>/dev/null)

  local count=${#snapshots[@]}
  if [ "$count" -gt "$retention" ]; then
    local to_delete=$((count - retention))
    for ((i = retention; i < count; i++)); do
      rm -f "${snapshots[$i]}"
    done
  fi
}
