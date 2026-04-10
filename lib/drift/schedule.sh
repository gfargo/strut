#!/usr/bin/env bash
# ==================================================
# lib/drift/schedule.sh — Drift monitoring cron job management
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Manages cron jobs for automated drift detection

# Source utils if not already sourced
set -euo pipefail

if [ -z "$RED" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$SCRIPT_DIR/utils.sh"
fi

# drift_schedule_install <stack> <env> [schedule]
# Installs a cron job for drift monitoring
# Default schedule: hourly (0 * * * *)
drift_schedule_install() {
  local stack="$1"
  local env="${2:-prod}"
  local schedule="${3:-0 * * * *}" # Default: hourly at minute 0

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local cli_path="$cli_root/strut"

  [ -f "$cli_path" ] || {
    error "CLI not found: $cli_path"
    return 1
  }

  # Create cron job command
  local cron_cmd="$schedule cd $cli_root && strut $stack drift monitor --env $env >> $cli_root/stacks/$stack/drift-history/monitor.log 2>&1"

  # Check if cron job already exists
  if crontab -l 2>/dev/null | grep -q "drift monitor.*$stack"; then
    warn "Drift monitoring cron job already exists for $stack"
    return 0
  fi

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

  # Remove cron job
  crontab -l 2>/dev/null | grep -v "drift monitor.*$stack" | crontab -

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
    cron_jobs=$(crontab -l 2>/dev/null | grep "drift monitor.*$stack" || echo "")
  else
    cron_jobs=$(crontab -l 2>/dev/null | grep "drift monitor" || echo "")
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
    stack_name=$(echo "$job" | grep -oP 'cli\.sh \K[^ ]+' || echo "unknown")

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
