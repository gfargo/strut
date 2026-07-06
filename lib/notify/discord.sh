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
    detail+="• ${key}: \`${val}\`"$'\n'
  done

  local text
  text="$(json_escape "${summary}"$'\n'"${detail}")"

  local payload="{\"content\":\"${text}\"}"

  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --max-time 5 \
    -d "$payload" "$url")

  case "$http_code" in
    2??) return 0 ;;
    *) warn "Discord webhook returned HTTP $http_code"; return 1 ;;
  esac
}
