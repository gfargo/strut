#!/usr/bin/env bash
# ==================================================
# lib/backup/retention.sh — Backup retention policy
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Enforces backup retention policies by deleting old backups

# calculate_backup_age <backup_file>
# Returns the age of a backup file in days
set -euo pipefail

calculate_backup_age() {
  local backup_file="$1"

  [ -f "$backup_file" ] || {
    error "Backup file not found: $backup_file"
    return 1
  }

  local now
  now=$(date +%s)

  local file_time
  file_time=$(stat -c%Y "$backup_file" 2>/dev/null || stat -f%m "$backup_file" 2>/dev/null)

  local age_seconds=$((now - file_time))
  local age_days=$((age_seconds / 86400))

  echo "$age_days"
}

# get_backup_list <stack> <service>
# Returns a sorted list of backups for a service (newest first)
get_backup_list() {
  local stack="$1"
  local service="$2"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_dir="$cli_root/stacks/$stack/backups"

  [ -d "$backup_dir" ] || {
    error "Backup directory not found: $backup_dir"
    return 1
  }

  # Determine file extension based on service
  local extension=""
  case "$service" in
    postgres)
      extension="sql"
      ;;
    neo4j)
      extension="dump"
      ;;
    gdrive-transcripts)
      extension="tar.gz"
      ;;
    mysql)
      extension="sql"
      ;;
    sqlite)
      extension="db"
      ;;
    *)
      error "Unknown service: $service"
      return 1
      ;;
  esac

  # List backups sorted by modification time (newest first)
  ls -t "$backup_dir/${service}-"*."$extension" 2>/dev/null
}

# delete_backup <backup_file> <reason>
# Deletes a backup file and logs the action
delete_backup() {
  local backup_file="$1"
  local reason="$2"

  [ -f "$backup_file" ] || {
    error "Backup file not found: $backup_file"
    return 1
  }

  local backup_filename
  backup_filename=$(basename "$backup_file")

  # Log deletion
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local stack
  stack=$(echo "$backup_file" | sed 's|.*/stacks/\([^/]*\)/.*|\1|')
  local retention_log="$cli_root/stacks/$stack/backups/retention.log"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  echo "[$timestamp] Deleted: $backup_filename - Reason: $reason" >>"$retention_log"

  # Delete metadata if exists
  local backup_id="${backup_filename%.*}"
  local metadata_file="$cli_root/stacks/$stack/backups/metadata/${backup_id}.json"
  [ -f "$metadata_file" ] && rm -f "$metadata_file"

  # Delete backup file
  rm -f "$backup_file"

  log "Deleted backup: $backup_filename ($reason)"
}

# enforce_retention_policy <stack> <service>
# Enforces retention policy for a specific service
enforce_retention_policy() {
  local stack="$1"
  local service="$2"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_conf="$cli_root/stacks/$stack/backup.conf"

  # Load retention policy from backup.conf
  local retain_days=30
  local retain_count=10

  if [ -f "$backup_conf" ]; then
    set -a
    source "$backup_conf"
    set +a
    retain_days="${BACKUP_RETAIN_DAYS:-30}"
    retain_count="${BACKUP_RETAIN_COUNT:-10}"
  fi

  log "Enforcing retention policy for $stack/$service"
  log "  Retain days: $retain_days"
  log "  Retain count: $retain_count"

  # Get list of backups
  local backups
  backups=$(get_backup_list "$stack" "$service")

  if [ -z "$backups" ]; then
    warn "No backups found for $service"
    return 0
  fi

  local total_count=0
  local deleted_count=0

  # Count total backups
  while IFS= read -r backup_file; do
    [ -f "$backup_file" ] || continue
    total_count=$((total_count + 1))
  done <<<"$backups"

  log "  Total backups: $total_count"

  # Process each backup
  local current_count=0
  while IFS= read -r backup_file; do
    [ -f "$backup_file" ] || continue
    current_count=$((current_count + 1))

    # Always keep the minimum number of backups
    if [ $current_count -le $retain_count ]; then
      continue
    fi

    # Check age
    local age_days
    age_days=$(calculate_backup_age "$backup_file")

    if [ "$age_days" -gt "$retain_days" ]; then
      delete_backup "$backup_file" "Age: ${age_days} days (policy: ${retain_days} days)"
      deleted_count=$((deleted_count + 1))
    fi
  done <<<"$backups"

  if [ $deleted_count -gt 0 ]; then
    ok "Deleted $deleted_count old backup(s)"
  else
    ok "No backups to delete (all within retention policy)"
  fi

  return 0
}

# enforce_retention_all <stack>
# Enforces retention policy for all services in a stack
enforce_retention_all() {
  local stack="$1"

  log "Enforcing retention policy for all services in $stack"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_dir="$cli_root/stacks/$stack/backups"

  [ -d "$backup_dir" ] || {
    error "Backup directory not found: $backup_dir"
    return 1
  }

  # Check for postgres backups
  if ls "$backup_dir"/postgres-*.sql >/dev/null 2>&1; then
    enforce_retention_policy "$stack" "postgres"
  fi

  # Check for neo4j backups
  if ls "$backup_dir"/neo4j-*.dump >/dev/null 2>&1; then
    enforce_retention_policy "$stack" "neo4j"
  fi

  # Check for gdrive backups
  if ls "$backup_dir"/gdrive-transcripts-*.tar.gz >/dev/null 2>&1; then
    enforce_retention_policy "$stack" "gdrive-transcripts"
  fi

  # Check for mysql backups
  if ls "$backup_dir"/mysql-*.sql >/dev/null 2>&1; then
    enforce_retention_policy "$stack" "mysql"
  fi

  # Check for sqlite backups
  if ls "$backup_dir"/sqlite-*.db >/dev/null 2>&1; then
    enforce_retention_policy "$stack" "sqlite"
  fi

  ok "Retention policy enforcement complete"
}

# check_storage_capacity <stack>
# Checks backup storage usage and sends alerts if threshold exceeded
check_storage_capacity() {
  local stack="$1"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_dir="$cli_root/stacks/$stack/backups"

  [ -d "$backup_dir" ] || {
    error "Backup directory not found: $backup_dir"
    return 1
  }

  # Get filesystem usage for backup directory
  local usage_percent
  usage_percent=$(df "$backup_dir" | tail -1 | awk '{print $5}' | sed 's/%//')

  log "Backup storage usage: ${usage_percent}%"

  # Check threshold (90%)
  if [ "$usage_percent" -ge 90 ]; then
    warn "Backup storage capacity warning: ${usage_percent}%"

    # Send alert
    source "$cli_root/lib/backup/alerts.sh" 2>/dev/null
    alert_storage_capacity "$stack" "$usage_percent"

    return 1
  fi

  ok "Storage capacity OK: ${usage_percent}%"
  return 0
}

# get_backup_storage_stats <stack>
# Returns storage statistics for backups
get_backup_storage_stats() {
  local stack="$1"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_dir="$cli_root/stacks/$stack/backups"

  [ -d "$backup_dir" ] || {
    error "Backup directory not found: $backup_dir"
    return 1
  }

  log "Backup storage statistics for $stack:"

  # Total size
  local total_size
  total_size=$(du -sh "$backup_dir" 2>/dev/null | awk '{print $1}')
  echo "  Total size: $total_size"

  # Count by service
  local postgres_count=0
  if ls "$backup_dir"/postgres-*.sql >/dev/null 2>&1; then
    postgres_count=$(ls "$backup_dir"/postgres-*.sql 2>/dev/null | wc -l)
  fi
  echo "  PostgreSQL backups: $postgres_count"

  local neo4j_count=0
  if ls "$backup_dir"/neo4j-*.dump >/dev/null 2>&1; then
    neo4j_count=$(ls "$backup_dir"/neo4j-*.dump 2>/dev/null | wc -l)
  fi
  echo "  Neo4j backups: $neo4j_count"

  local mysql_count=0
  if ls "$backup_dir"/mysql-*.sql >/dev/null 2>&1; then
    mysql_count=$(ls "$backup_dir"/mysql-*.sql 2>/dev/null | wc -l)
  fi
  echo "  MySQL backups: $mysql_count"

  local sqlite_count=0
  if ls "$backup_dir"/sqlite-*.db >/dev/null 2>&1; then
    sqlite_count=$(ls "$backup_dir"/sqlite-*.db 2>/dev/null | wc -l)
  fi
  echo "  SQLite backups: $sqlite_count"

  # Oldest backup
  local oldest_backup
  oldest_backup=$(find "$backup_dir" \( -name "*.sql" -o -name "*.dump" -o -name "*.db" \) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | tail -1)
  if [ -n "$oldest_backup" ] && [ -f "$oldest_backup" ]; then
    local oldest_age
    oldest_age=$(calculate_backup_age "$oldest_backup")
    echo "  Oldest backup: $oldest_age days old"
  fi

  # Newest backup
  local newest_backup
  newest_backup=$(find "$backup_dir" \( -name "*.sql" -o -name "*.dump" -o -name "*.db" \) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
  if [ -n "$newest_backup" ] && [ -f "$newest_backup" ]; then
    local newest_age
    newest_age=$(calculate_backup_age "$newest_backup")
    echo "  Newest backup: $newest_age days old"
  fi

  # Filesystem usage
  local usage_percent
  usage_percent=$(df "$backup_dir" | tail -1 | awk '{print $5}')
  echo "  Filesystem usage: $usage_percent"

  return 0
}

# install_retention_cron <stack>
# Installs a cron job to enforce retention policy daily
install_retention_cron() {
  local stack="$1"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local retention_cmd="cd $cli_root && strut $stack backup retention enforce --env prod"

  # Create cron job entry (run daily at 4 AM)
  local cron_comment="# strut retention: $stack"
  local cron_entry="0 4 * * * $retention_cmd >> $cli_root/stacks/$stack/backups/retention-cron.log 2>&1"

  # Check if cron job already exists
  if crontab -l 2>/dev/null | grep -q "strut retention: $stack"; then
    warn "Retention cron job already exists for $stack"
    return 0
  fi

  # Add new cron job
  (
    crontab -l 2>/dev/null
    echo ""
    echo "$cron_comment"
    echo "$cron_entry"
  ) | crontab -

  ok "Retention cron job installed for $stack"
  log "Schedule: Daily at 4:00 AM"
  log "Command: $retention_cmd"

  return 0
}

# remove_retention_cron <stack>
# Removes the retention policy cron job
remove_retention_cron() {
  local stack="$1"

  if ! crontab -l 2>/dev/null | grep -q "strut retention: $stack"; then
    warn "No retention cron job found for $stack"
    return 1
  fi

  # Remove cron job
  crontab -l 2>/dev/null | grep -v "strut retention: $stack" | crontab -

  ok "Retention cron job removed for $stack"
  return 0
}
