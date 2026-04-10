#!/usr/bin/env bash
# ==================================================
# lib/backup/schedule.sh — Backup scheduling management
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Manages cron-based backup schedules

# validate_cron_expression <expression>
# Validates a cron expression format
set -euo pipefail

validate_cron_expression() {
  local expr="$1"

  # Basic validation: should have 5 fields (minute hour day month weekday)
  local field_count
  field_count=$(echo "$expr" | awk '{print NF}')

  if [ "$field_count" -ne 5 ]; then
    error "Invalid cron expression: must have 5 fields (minute hour day month weekday)"
    return 1
  fi

  # Additional validation could be added here
  return 0
}

# install_backup_schedule <stack> <service> <cron_expression> [env_name]
# Installs a cron job for automated backups
install_backup_schedule() {
  local stack="$1"
  local service="$2"
  local cron_expr="$3"
  local env_name="${4:-prod}"

  validate_cron_expression "$cron_expr" || {
    error "Invalid cron expression: $cron_expr"
    return 1
  }

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_cmd="cd $cli_root && strut $stack backup $service --env $env_name"

  # Create cron job entry
  local cron_comment="# strut backup: $stack/$service"
  local cron_entry="$cron_expr $backup_cmd >> $cli_root/stacks/$stack/backups/cron.log 2>&1"

  # Check if cron job already exists
  if crontab -l 2>/dev/null | grep -q "strut backup: $stack/$service"; then
    warn "Cron job already exists for $stack/$service"
    log "Updating existing schedule..."

    # Remove old entry and add new one
    (
      crontab -l 2>/dev/null | grep -v "strut backup: $stack/$service"
      echo "$cron_comment"
      echo "$cron_entry"
    ) | crontab -
  else
    # Add new cron job
    (
      crontab -l 2>/dev/null
      echo ""
      echo "$cron_comment"
      echo "$cron_entry"
    ) | crontab -
  fi

  ok "Backup schedule installed for $stack/$service"
  log "Schedule: $cron_expr"
  log "Command: $backup_cmd"

  # Store schedule in backup.conf
  update_backup_conf_schedule "$stack" "$service" "$cron_expr"

  return 0
}

# remove_backup_schedule <stack> <service>
# Removes a cron job for automated backups
remove_backup_schedule() {
  local stack="$1"
  local service="$2"

  if ! crontab -l 2>/dev/null | grep -q "strut backup: $stack/$service"; then
    warn "No cron job found for $stack/$service"
    return 1
  fi

  # Remove cron job
  crontab -l 2>/dev/null | grep -v "strut backup: $stack/$service" | crontab -

  ok "Backup schedule removed for $stack/$service"
  return 0
}

# list_backup_schedules <stack>
# Lists all backup schedules for a stack
list_backup_schedules() {
  local stack="$1"

  log "Backup schedules for stack: $stack"
  echo ""

  local found=0
  while IFS= read -r line; do
    if [[ "$line" =~ strut\ backup:\ $stack/ ]]; then
      found=1
      local service
      service=$(echo "$line" | sed "s/.*$stack\///")
      echo "Service: $service"

      # Read next line for cron expression
      read -r cron_line
      local cron_expr
      cron_expr=$(echo "$cron_line" | awk '{print $1, $2, $3, $4, $5}')
      echo "Schedule: $cron_expr"
      echo "Command: $(echo "$cron_line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}')"
      echo ""
    fi
  done < <(crontab -l 2>/dev/null)

  if [ $found -eq 0 ]; then
    warn "No backup schedules found for $stack"
    return 1
  fi

  return 0
}

# update_backup_conf_schedule <stack> <service> <cron_expression>
# Updates the backup.conf file with schedule information
update_backup_conf_schedule() {
  local stack="$1"
  local service="$2"
  local cron_expr="$3"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_conf="$cli_root/stacks/$stack/backup.conf"

  [ -f "$backup_conf" ] || {
    warn "backup.conf not found, creating default"
    create_default_backup_conf "$stack"
  }

  local var_name="BACKUP_SCHEDULE_$(echo "$service" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

  # Update or add schedule in backup.conf
  if grep -q "^$var_name=" "$backup_conf"; then
    # Update existing
    sed -i.bak "s|^$var_name=.*|$var_name=\"$cron_expr\"|" "$backup_conf"
  else
    # Add new
    echo "$var_name=\"$cron_expr\"" >>"$backup_conf"
  fi
}

# create_default_backup_conf <stack>
# Creates a default backup.conf file
create_default_backup_conf() {
  local stack="$1"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_conf="$cli_root/stacks/$stack/backup.conf"

  cat >"$backup_conf" <<'EOF'
# ==================================================
# backup.conf — Backup schedule and retention policy
# ==================================================

# ── Schedule ──────────────────────────────────────
BACKUP_SCHEDULE_POSTGRES="0 2 * * *"   # 02:00 UTC daily
BACKUP_SCHEDULE_NEO4J="0 3 * * 0"      # 03:00 UTC weekly (Sunday)

# ── Retention ─────────────────────────────────────
BACKUP_RETAIN_DAYS=30          # Delete backups older than 30 days
BACKUP_RETAIN_COUNT=10         # Always keep at least 10 backups

# ── Targets ───────────────────────────────────────
BACKUP_POSTGRES=true
BACKUP_NEO4J=true

# ── Storage ───────────────────────────────────────
BACKUP_LOCAL_DIR="${BACKUP_PATH:-./backups}"
EOF

  ok "Created default backup.conf: $backup_conf"
}

# install_default_schedules <stack> [env_name]
# Installs default backup schedules from backup.conf
install_default_schedules() {
  local stack="$1"
  local env_name="${2:-prod}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_conf="$cli_root/stacks/$stack/backup.conf"

  [ -f "$backup_conf" ] || {
    warn "backup.conf not found, creating default"
    create_default_backup_conf "$stack"
  }

  # Source backup.conf
  set -a
  source "$backup_conf"
  set +a

  log "Installing default backup schedules for $stack..."

  # Install postgres schedule if enabled
  if [ "${BACKUP_POSTGRES:-true}" = "true" ] && [ -n "${BACKUP_SCHEDULE_POSTGRES:-}" ]; then
    install_backup_schedule "$stack" "postgres" "$BACKUP_SCHEDULE_POSTGRES" "$env_name"
  fi

  # Install neo4j schedule if enabled
  if [ "${BACKUP_NEO4J:-false}" = "true" ] && [ -n "${BACKUP_SCHEDULE_NEO4J:-}" ]; then
    install_backup_schedule "$stack" "neo4j" "$BACKUP_SCHEDULE_NEO4J" "$env_name"
  fi

  # Install mysql schedule if enabled
  if [ "${BACKUP_MYSQL:-false}" = "true" ] && [ -n "${BACKUP_SCHEDULE_MYSQL:-}" ]; then
    install_backup_schedule "$stack" "mysql" "$BACKUP_SCHEDULE_MYSQL" "$env_name"
  fi

  # Install sqlite schedule if enabled
  if [ "${BACKUP_SQLITE:-false}" = "true" ] && [ -n "${BACKUP_SCHEDULE_SQLITE:-}" ]; then
    install_backup_schedule "$stack" "sqlite" "$BACKUP_SCHEDULE_SQLITE" "$env_name"
  fi

  ok "Default schedules installed"
}

# check_missed_backups <stack>
# Checks if any scheduled backups were missed
check_missed_backups() {
  local stack="$1"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_dir="$cli_root/stacks/$stack/backups"

  [ -d "$backup_dir" ] || {
    warn "Backup directory not found"
    return 1
  }

  local now
  now=$(date +%s)
  local two_hours=$((2 * 3600))

  log "Checking for missed backups..."

  # Get crontab entries as array
  local crontab_lines=()
  while IFS= read -r line; do
    crontab_lines+=("$line")
  done < <(crontab -l 2>/dev/null)

  # Check each service schedule
  local found_schedules=0
  for ((i = 0; i < ${#crontab_lines[@]}; i++)); do
    local line="${crontab_lines[$i]}"

    if [[ "$line" =~ strut\ backup:\ $stack/ ]]; then
      found_schedules=1
      local service
      service=$(echo "$line" | sed "s/.*$stack\///")

      # Get next line for cron expression
      if [ $((i + 1)) -lt ${#crontab_lines[@]} ]; then
        local cron_line="${crontab_lines[$((i + 1))]}"
        local cron_expr
        cron_expr=$(echo "$cron_line" | awk '{print $1, $2, $3, $4, $5}')

        # Find latest backup for this service
        local latest_backup=""
        if [ "$service" = "postgres" ]; then
          latest_backup=$(ls -t "$backup_dir/${service}-"*.sql 2>/dev/null | head -1)
        elif [ "$service" = "neo4j" ]; then
          latest_backup=$(ls -t "$backup_dir/${service}-"*.dump 2>/dev/null | head -1)
        elif [ "$service" = "mysql" ]; then
          latest_backup=$(ls -t "$backup_dir/${service}-"*.sql 2>/dev/null | head -1)
        elif [ "$service" = "sqlite" ]; then
          latest_backup=$(ls -t "$backup_dir/${service}-"*.db 2>/dev/null | head -1)
        fi

        if [ -z "$latest_backup" ]; then
          warn "No backups found for $service"
          continue
        fi

        # Get backup timestamp
        local backup_time
        backup_time=$(stat -c%Y "$latest_backup" 2>/dev/null || stat -f%m "$latest_backup" 2>/dev/null)
        local time_diff=$((now - backup_time))

        # Calculate expected backup interval from cron expression
        # This is simplified - a full implementation would parse cron properly
        local expected_interval
        if [[ "$cron_expr" == *"* * *"* ]]; then
          expected_interval=$((24 * 3600)) # Daily
        elif [[ "$cron_expr" == *"* * 0"* ]]; then
          expected_interval=$((7 * 24 * 3600)) # Weekly
        else
          expected_interval=$((24 * 3600)) # Default to daily
        fi

        # Check if backup is overdue (expected interval + 2 hours grace period)
        if [ $time_diff -gt $((expected_interval + two_hours)) ]; then
          warn "Missed backup detected for $service"
          log "  Last backup: $(date -d "@$backup_time" 2>/dev/null || date -r "$backup_time" 2>/dev/null)"
          log "  Expected interval: $((expected_interval / 3600)) hours"
          log "  Time since last backup: $((time_diff / 3600)) hours"

          # Send alert
          source "$cli_root/lib/backup/alerts.sh" 2>/dev/null
          alert_missed_backup "$stack" "$service" "$cron_expr"
        else
          ok "Backup schedule OK for $service (last backup: $((time_diff / 3600)) hours ago)"
        fi
      fi
    fi
  done

  if [ $found_schedules -eq 0 ]; then
    warn "No backup schedules found for $stack"
    return 1
  fi

  ok "Missed backup check complete"
}

# get_next_backup_time <cron_expression>
# Calculates the next execution time for a cron expression (simplified)
get_next_backup_time() {
  local cron_expr="$1"

  # This is a simplified implementation
  # A full implementation would use a cron parser library

  local minute hour day month weekday
  read -r minute hour day month weekday <<<"$cron_expr"

  local now
  now=$(date +"%Y-%m-%d %H:%M")

  # For daily backups (most common case)
  if [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$weekday" = "*" ]; then
    local next_time
    next_time=$(date -d "today $hour:$minute" +"%Y-%m-%d %H:%M" 2>/dev/null)

    # If time has passed today, show tomorrow
    if [ "$(date +%s)" -gt "$(date -d "$next_time" +%s 2>/dev/null)" ]; then
      next_time=$(date -d "tomorrow $hour:$minute" +"%Y-%m-%d %H:%M" 2>/dev/null)
    fi

    echo "$next_time"
  else
    echo "Next execution time calculation not implemented for complex cron expressions"
  fi
}
