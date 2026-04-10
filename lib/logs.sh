#!/usr/bin/env bash
# ==================================================
# lib/logs.sh — Log tail, download, and rotation
# ==================================================
# Requires: lib/utils.sh sourced first

set -euo pipefail

# logs_tail <compose_cmd> [service] [--follow]
#
# Tails the last 200 log lines for a specific service, or all services if
# no service name is given. Pass --follow / -f to stream new output.
#
# Args:
#   compose_cmd — Full docker compose command prefix
#   service     — Service name to tail (omit for all services)
#   --follow    — Stream logs continuously (-f also accepted)
logs_tail() {
  local compose_cmd="$1"
  local service="${2:-}"
  local follow="${3:-}"
  local tail_args="--tail=200"
  [ "$follow" = "--follow" ] || [ "$follow" = "-f" ] && tail_args="$tail_args -f"

  if [ -n "$service" ]; then
    $compose_cmd logs $tail_args "$service"
  else
    $compose_cmd logs $tail_args
  fi
}

# logs_download <compose_cmd> [service] [since]
#
# Downloads logs for a service (or all services) to a timestamped local file.
# The output filename follows the pattern "<service>-<YYYYMMDD-HHMMSS>.log".
#
# Args:
#   compose_cmd — Full docker compose command prefix
#   service     — Service name (omit for all services)
#   since       — Docker duration string, e.g. "24h", "7d" (default: "24h")
#
# Side effects: Creates a log file in the current directory
logs_download() {
  local compose_cmd="$1"
  local service="${2:-}"
  local since="${3:-24h}"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local out_file="${service:-all}-${timestamp}.log"

  log "Downloading logs (since $since)..."
  if [ -n "$service" ]; then
    $compose_cmd logs --since "$since" "$service" > "$out_file" 2>&1
  else
    $compose_cmd logs --since "$since" > "$out_file" 2>&1
  fi
  ok "Logs saved to: $out_file"
}

# logs_rotate [--days <n>]
#
# Truncates (zeros out) Docker container log files older than N days.
# Must be run directly on the Docker host. Prompts for confirmation before
# truncating.
#
# Args:
#   --days <n> — Age threshold in days (default: 7)
#
# Requires env: DOCKER_LOG_DIR (default: /var/lib/docker/containers)
# Returns: 0 on success, 1 if log directory not found
# Side effects: Truncates log files on disk
logs_rotate() {
  local days=7
  while [[ $# -gt 0 ]]; do
    case $1 in
      --days) days="$2"; shift 2 ;;
      *)      shift ;;
    esac
  done

  log "Finding Docker log files older than $days days..."

  local log_dir="${DOCKER_LOG_DIR:-/var/lib/docker/containers}"
  if [ ! -d "$log_dir" ]; then
    warn "Docker log directory not found: $log_dir (are you running on the host?)"
    return 1
  fi

  local files
  files=$(find "$log_dir" -name "*.log" -mtime +"$days" 2>/dev/null)
  if [ -z "$files" ]; then
    ok "No log files older than $days days found"
    return 0
  fi

  local count
  count=$(echo "$files" | wc -l | tr -d ' ')
  local total_size
  total_size=$(echo "$files" | xargs du -sh 2>/dev/null | tail -1 | awk '{print $1}' || echo "unknown")

  warn "Found $count log file(s) older than $days days (approx $total_size)"
  if confirm "Truncate (zero out) these log files?"; then
    echo "$files" | xargs truncate -s 0
    ok "Log files truncated"
  else
    ok "Skipped log rotation"
  fi
}
