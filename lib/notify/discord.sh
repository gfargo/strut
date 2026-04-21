#!/usr/bin/env bash
# ==================================================
# lib/notify/discord.sh — Discord webhook provider
# ==================================================
# Posts events as Discord webhook messages. Uses the `content` field
# with a compact key/value rendering so messages are legible without
# requiring embeds.

set -euo pipefail

# notify_discord_send <webhook_url> <event> [key=value ...]
notify_discord_send() {
  local url="$1"
  local event="$2"
  shift 2 || true

  command -v curl >/dev/null 2>&1 || {
    warn "curl not available — skipping Discord notification"
    return 1
  }

  local summary="**strut event: ${event}**"
  local detail=""
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    detail+="• ${key}: \`${val}\`\\n"
  done

  summary="${summary//\\/\\\\}"
  summary="${summary//\"/\\\"}"
  detail="${detail//\\/\\\\}"
  detail="${detail//\"/\\\"}"

  local payload="{\"content\":\"${summary}\\n${detail}\"}"

  curl -sS -X POST -H 'Content-Type: application/json' \
    --max-time 5 \
    -d "$payload" "$url" >/dev/null
}
