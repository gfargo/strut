#!/usr/bin/env bash
# ==================================================
# lib/drift/schedule.sh — Drift monitoring cron job management
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Manages cron jobs for automated drift detection

# Source utils if not already sourced
set -euo pipefail

if [ -z "${RED:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$SCRIPT_DIR/utils.sh"
fi

# Managed drift cron jobs carry an exact marker and a stack-specific log path.
# Match either form so jobs created before the marker was introduced are still
# upgraded/removed safely without confusing `api` with `api-v2` (strut#402).
_drift_cron_marker() {
  printf '# strut:drift:%s' "$1"
}

_drift_cron_log_path() {
  local stack="$1"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  printf '%s/stacks/%s/drift-history/monitor.log' "$cli_root" "$stack"
}

_drift_cron_line_matches_stack() {
  local line="$1"
  local stack="$2"
  local marker log_path
  marker=$(_drift_cron_marker "$stack")
  log_path=$(_drift_cron_log_path "$stack")

  # Managed markers are appended at end-of-line. Requiring that boundary keeps
  # `api` distinct from `api-v2`; the legacy log path is already delimited by
  # `/stacks/<stack>/drift-history/` and is safe to match literally.
  case "$line" in
    *"$marker"|*"$log_path"*) return 0 ;;
    *) return 1 ;;
  esac
}

_drift_cron_has_stack() {
  local stack="$1" line
  while IFS= read -r line; do
    _drift_cron_line_matches_stack "$line" "$stack" && return 0
  done < <(crontab -l 2>/dev/null)
  return 1
}

_drift_cron_without_stack() {
  local stack="$1" line
  while IFS= read -r line; do
    _drift_cron_line_matches_stack "$line" "$stack" || printf '%s\n' "$line"
  done
}

_drift_cron_for_stack() {
  local stack="$1" line
  while IFS= read -r line; do
    _drift_cron_line_matches_stack "$line" "$stack" && printf '%s\n' "$line"
  done < <(crontab -l 2>/dev/null)
}

# drift_schedule_install <stack> <env> [schedule]
# Installs a cron job for drift monitoring
# Default schedule: hourly (0 * * * *)
drift_schedule_install() {
  local stack="$1"
  local env="${2:-prod}"
  local schedule="${3:-0 * * * *}" # Default: hourly at minute 0

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local strut_bin
  strut_bin=$(resolve_strut_binary)

  [ -f "$strut_bin" ] || {
    error "CLI not found: $strut_bin"
    return 1
  }

  # Check if this exact stack's cron job already exists.
  if _drift_cron_has_stack "$stack"; then
    warn "Drift monitoring cron job already exists for $stack"
    return 0
  fi

  ensure_cron_env_header

  # Create cron job command
  local drift_cmd="cd $cli_root && $strut_bin $stack drift monitor --env $env"
  local log_file="$cli_root/stacks/$stack/drift-history/monitor.log"
  local cron_cmd
  cron_cmd="$(build_cron_job "drift-$stack" "$schedule" "$drift_cmd" "$log_file") $(_drift_cron_marker "$stack")"

  # Add cron job
  (
    crontab -l 2>/dev/null
    echo "$cron_cmd"
  ) | crontab -

  ok "Drift monitoring cron job installed for $stack"
  log "  Schedule: $schedule (hourly)"
  log "  Command: strut $stack drift monitor --env $env"

  return 0
}

# drift_schedule_remove <stack>
# Removes the drift monitoring cron job for a stack
drift_schedule_remove() {
  local stack="$1"

  # Remove only this exact stack's managed job. The filter keeps sibling
  # stacks whose names merely share a prefix.
  crontab -l 2>/dev/null | _drift_cron_without_stack "$stack" | crontab - || true

  ok "Drift monitoring cron job removed for $stack"
  return 0
}

# drift_schedule_list [stack]
# Lists all drift monitoring cron jobs
drift_schedule_list() {
  local stack="${1:-}"

  echo -e "${BLUE}=================================================="
  echo -e "  Drift Monitoring Schedules"
  echo -e "==================================================${NC}"
  echo ""

  local cron_jobs
  if [ -n "$stack" ]; then
    cron_jobs=$(_drift_cron_for_stack "$stack")
  else
    cron_jobs=$(crontab -l 2>/dev/null | grep -F "drift monitor" || true)
  fi

  if [ -z "$cron_jobs" ]; then
    log "No drift monitoring cron jobs found"
    return 0
  fi

  echo "$cron_jobs" | while IFS= read -r job; do
    # Extract schedule and stack from cron job
    local schedule
    local stack_name
    schedule=$(echo "$job" | awk '{print $1, $2, $3, $4, $5}')
    stack_name=$(echo "$job" | sed -n 's/.*cli\.sh \([^ ]*\).*/\1/p')
    [ -z "$stack_name" ] && stack_name="unknown"

    echo "Stack: $stack_name"
    echo "  Schedule: $schedule"
    echo "  Full command: $job"
    echo ""
  done

  return 0
}

# drift_schedule_enable <stack> <env>
# Enables drift monitoring for a stack (installs cron job)
drift_schedule_enable() {
  local stack="$1"
  local env="${2:-prod}"

  log "Enabling drift monitoring for $stack..."
  drift_schedule_install "$stack" "$env"

  return $?
}

# drift_schedule_disable <stack>
# Disables drift monitoring for a stack (removes cron job)
drift_schedule_disable() {
  local stack="$1"

  log "Disabling drift monitoring for $stack..."
  drift_schedule_remove "$stack"

  return $?
}
