#!/usr/bin/env bash
# ==================================================
# lib/backup/alerts.sh — Backup alert notifications
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Sends alerts for backup failures and verification issues

# send_backup_alert <stack> <service> <alert_type> <message>
# Sends a backup-related alert through configured channels
set -euo pipefail

send_backup_alert() {
  local stack="$1"
  local service="$2"
  local alert_type="$3"
  local message="$4"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local alert_title="[Backup Alert] $stack/$service - $alert_type"
  local alert_body="$message

Stack: $stack
Service: $service
Alert Type: $alert_type
Timestamp: $timestamp"

  # Log alert locally
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local alert_log="$cli_root/stacks/$stack/backups/alerts.log"
  echo "[$timestamp] $alert_type: $message" >>"$alert_log"

  # Send email alert if configured (via monitoring system)
  if [ -n "${ALERT_EMAIL_TO:-}" ] && [ -n "${RESEND_API_KEY:-}" ]; then
    send_email_alert "$alert_title" "$alert_body"
  fi

  # Send Slack alert if configured
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    send_slack_alert "$alert_title" "$alert_body"
  fi

  # If no alert channels configured, just log
  if [ -z "${ALERT_EMAIL_TO:-}" ] && [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    warn "No alert channels configured. Alert logged to: $alert_log"
  fi
}

# send_email_alert <subject> <body>
# Sends email alert via Resend SMTP
send_email_alert() {
  local subject="$1"
  local body="$2"

  # This would integrate with the monitoring system's alertmanager
  # For now, we'll use a simple curl to Resend API
  if command -v curl &>/dev/null && [ -n "${RESEND_API_KEY:-}" ]; then
    curl -s -X POST "https://api.resend.com/emails" \
      -H "Authorization: Bearer ${RESEND_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{
        \"from\": \"${ALERT_EMAIL_FROM:-alerts@yourdomain.com}\",
        \"to\": [\"${ALERT_EMAIL_TO}\"],
        \"subject\": \"$subject\",
        \"text\": \"$body\"
      }" >/dev/null 2>&1
  fi
}

# send_slack_alert <title> <message>
# Sends Slack alert via webhook
send_slack_alert() {
  local title="$1"
  local message="$2"

  if command -v curl &>/dev/null && [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    curl -s -X POST "${SLACK_WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d "{
        \"text\": \"$title\",
        \"blocks\": [
          {
            \"type\": \"section\",
            \"text\": {
              \"type\": \"mrkdwn\",
              \"text\": \"$message\"
            }
          }
        ]
      }" >/dev/null 2>&1
  fi
}

# alert_verification_failure <stack> <backup_file> <error_message>
# Sends alert when backup verification fails
alert_verification_failure() {
  local stack="$1"
  local backup_file="$2"
  local error_message="$3"

  local backup_filename
  backup_filename=$(basename "$backup_file")

  local message="Backup verification failed for $backup_filename

Error: $error_message

Action Required: Investigate backup integrity and re-run verification.
Command: strut $stack backup verify $backup_filename --env prod"

  send_backup_alert "$stack" "backup-verification" "VERIFICATION_FAILED" "$message"
}

# alert_backup_failure <stack> <service> <error_message>
# Sends alert when backup creation fails
alert_backup_failure() {
  local stack="$1"
  local service="$2"
  local error_message="$3"

  local message="Backup creation failed for $service

Error: $error_message

Action Required: Check service health and storage capacity.
Command: strut $stack backup $service --env prod"

  send_backup_alert "$stack" "$service" "BACKUP_FAILED" "$message"
}

# alert_missed_backup <stack> <service> <scheduled_time>
# Sends alert when a scheduled backup is missed
alert_missed_backup() {
  local stack="$1"
  local service="$2"
  local scheduled_time="$3"

  local message="Scheduled backup was not executed

Service: $service
Scheduled Time: $scheduled_time
Missed By: >2 hours

Action Required: Check cron jobs and service availability.
Command: crontab -l | grep backup"

  send_backup_alert "$stack" "$service" "MISSED_BACKUP" "$message"
}

# alert_storage_capacity <stack> <usage_percent>
# Sends alert when backup storage exceeds threshold
alert_storage_capacity() {
  local stack="$1"
  local usage_percent="$2"

  local message="Backup storage capacity warning

Current Usage: ${usage_percent}%
Threshold: 90%

Action Required: Review retention policy or increase storage.
Command: strut $stack backup list --env prod"

  send_backup_alert "$stack" "storage" "STORAGE_WARNING" "$message"
}
