#!/usr/bin/env bash
# ==================================================
# lib/drift/alerts.sh — Drift detection alert notifications
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Sends alerts for configuration drift detection

# Source utils if not already sourced
set -euo pipefail

if [ -z "$RED" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$SCRIPT_DIR/utils.sh"
fi

# send_drift_alert <stack> <env> <alert_type> <message> <files_count>
# Sends a drift-related alert through configured channels
send_drift_alert() {
  local stack="$1"
  local env="$2"
  local alert_type="$3"
  local message="$4"
  local files_count="${5:-0}"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local alert_title="[Drift Alert] $stack ($env) - $alert_type"
  local alert_body="$message

Stack: $stack
Environment: $env
Alert Type: $alert_type
Files Affected: $files_count
Timestamp: $timestamp"

  # Log alert locally
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local alert_log="$cli_root/stacks/$stack/drift-history/alerts.log"
  mkdir -p "$(dirname "$alert_log")"
  echo "[$timestamp] $alert_type: $message (files: $files_count)" >>"$alert_log"

  # Send email alert if configured
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

# alert_drift_detected <stack> <env> <files_count> <files_list>
# Sends alert when configuration drift is detected
alert_drift_detected() {
  local stack="$1"
  local env="$2"
  local files_count="$3"
  local files_list="$4"

  local message="Configuration drift detected!

Files with drift:
$files_list

Action Required: Review changes and apply git-tracked configuration.
Commands:
  - View drift: strut $stack drift report --env $env
  - Fix drift: strut $stack drift fix --env $env
  - Dry-run: strut $stack drift fix --env $env --dry-run"

  send_drift_alert "$stack" "$env" "DRIFT_DETECTED" "$message" "$files_count"
}

# alert_drift_fixed <stack> <env> <files_count> <method>
# Sends alert when drift is automatically fixed
alert_drift_fixed() {
  local stack="$1"
  local env="$2"
  local files_count="$3"
  local method="${4:-manual}"

  local message="Configuration drift has been fixed

Method: $method
Files Fixed: $files_count

The git-tracked configuration has been applied successfully."

  send_drift_alert "$stack" "$env" "DRIFT_FIXED" "$message" "$files_count"
}

# alert_drift_fix_failed <stack> <env> <error_message>
# Sends alert when drift auto-fix fails
alert_drift_fix_failed() {
  local stack="$1"
  local env="$2"
  local error_message="$3"

  local message="Drift auto-fix failed!

Error: $error_message

Action Required: Manual intervention needed.
Command: strut $stack drift fix --env $env"

  send_drift_alert "$stack" "$env" "DRIFT_FIX_FAILED" "$message" "0"
}
