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
    detail+="• ${key}: \`${val}\`"$'\n'
  done

  local text
  text="$(json_escape "${summary}"$'\n'"${detail}")"

  local payload="{\"text\":\"${text}\"}"

  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --max-time 5 \
    -d "$payload" "$url")

  case "$http_code" in
    2??) return 0 ;;
    *) warn "Slack webhook returned HTTP $http_code"; return 1 ;;
  esac
}
