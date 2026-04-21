#!/usr/bin/env bash
# ==================================================
# lib/notify/slack.sh — Slack webhook provider
# ==================================================
# Posts events as Slack Incoming Webhook messages. The payload is a
# minimal JSON with `text` and a compact key/value block so messages
# are legible in Slack without custom formatting.

set -euo pipefail

# notify_slack_send <webhook_url> <event> [key=value ...]
notify_slack_send() {
  local url="$1"
  local event="$2"
  shift 2 || true

  command -v curl >/dev/null 2>&1 || {
    warn "curl not available — skipping Slack notification"
    return 1
  }

  # Build a human-readable summary line
  local summary="strut event: *${event}*"
  local detail=""
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    detail+="• ${key}: \`${val}\`\\n"
  done

  # Escape for JSON embedding
  summary="${summary//\\/\\\\}"
  summary="${summary//\"/\\\"}"
  detail="${detail//\\/\\\\}"
  detail="${detail//\"/\\\"}"

  local payload="{\"text\":\"${summary}\\n${detail}\"}"

  curl -sS -X POST -H 'Content-Type: application/json' \
    --max-time 5 \
    -d "$payload" "$url" >/dev/null
}
