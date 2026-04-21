#!/usr/bin/env bash
# ==================================================
# lib/notify/webhook.sh — Generic JSON webhook provider
# ==================================================
# Posts events as a raw JSON POST with `{"event": "...", ...kv}` body.
# Use for integrating with custom ops systems, PagerDuty-compatible
# endpoints, or anything that speaks JSON-over-HTTP.

set -euo pipefail

# notify_webhook_send <url> <event> [key=value ...]
notify_webhook_send() {
  local url="$1"
  local event="$2"
  shift 2 || true

  command -v curl >/dev/null 2>&1 || {
    warn "curl not available — skipping webhook notification"
    return 1
  }

  local payload
  payload=$(_notify_payload_json "$event" "$@")

  curl -sS -X POST -H 'Content-Type: application/json' \
    --max-time 5 \
    -d "$payload" "$url" >/dev/null
}
