#!/usr/bin/env bash
# ==================================================
# lib/notify.sh — Event notification dispatcher
# ==================================================
# Reads notifications.conf (from Project_Root), dispatches lifecycle
# events (deploy.success, backup.success, health.fail, drift.detected,
# etc.) to configured providers (Slack, Discord, generic webhook).
#
# Notification failures never fail the underlying action — the dispatcher
# always returns 0.
#
# Config format (notifications.conf — shell-friendly, same style as
# strut.conf):
#
#   SLACK_WEBHOOK=https://hooks.slack.com/services/...
#   SLACK_EVENTS=deploy.success,deploy.fail,health.fail
#   DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
#   DISCORD_EVENTS=deploy.fail
#   WEBHOOK_URL=https://ops.example.com/strut
#   WEBHOOK_EVENTS=*

set -euo pipefail

NOTIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notify"
[ -f "$NOTIFY_LIB_DIR/slack.sh" ]   && source "$NOTIFY_LIB_DIR/slack.sh"
[ -f "$NOTIFY_LIB_DIR/discord.sh" ] && source "$NOTIFY_LIB_DIR/discord.sh"
[ -f "$NOTIFY_LIB_DIR/webhook.sh" ] && source "$NOTIFY_LIB_DIR/webhook.sh"

# Path to the notifications config. Set by notify_load_config; callers
# usually don't need to touch this directly.
NOTIFY_CONFIG_LOADED="${NOTIFY_CONFIG_LOADED:-false}"

# notify_load_config [path]
#
# Sources notifications.conf if present. Search order:
#   1. Explicit path argument (if provided)
#   2. $NOTIFICATIONS_CONF env var
#   3. $PROJECT_ROOT/notifications.conf
#   4. $CLI_ROOT/notifications.conf (fallback)
#
# Safe to call multiple times — idempotent.
notify_load_config() {
  [ "$NOTIFY_CONFIG_LOADED" = "true" ] && return 0

  local conf="${1:-}"
  if [ -z "$conf" ]; then
    conf="${NOTIFICATIONS_CONF:-}"
  fi
  if [ -z "$conf" ] && [ -n "${PROJECT_ROOT:-}" ]; then
    conf="$PROJECT_ROOT/notifications.conf"
  fi
  if [ -z "$conf" ] || [ ! -f "$conf" ]; then
    conf="${CLI_ROOT:-}/notifications.conf"
  fi

  if [ -f "$conf" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$conf"
    set +a
  fi

  NOTIFY_CONFIG_LOADED=true
  return 0
}

# _notify_provider_subscribed <provider_events> <event>
#
# Returns 0 if the provider subscribes to <event> based on its comma-
# separated event list. "*" means all events. Empty list means no match.
_notify_provider_subscribed() {
  local events_csv="$1"
  local event="$2"
  [ -z "$events_csv" ] && return 1
  [ "$events_csv" = "*" ] && return 0

  # Disable pathname expansion so a bare `*` in the CSV doesn't glob
  # against the filesystem when the string is expanded by the for loop.
  local _noglob_restore=0
  case $- in *f*) ;; *) set -f; _noglob_restore=1 ;; esac

  local IFS=','
  local e rc=1
  for e in $events_csv; do
    # Trim whitespace
    e="${e#"${e%%[![:space:]]*}"}"
    e="${e%"${e##*[![:space:]]}"}"
    if [ "$e" = "$event" ] || [ "$e" = "*" ]; then
      rc=0
      break
    fi
  done

  [ "$_noglob_restore" = "1" ] && set +f
  return "$rc"
}

# notify_event <event> [key=value ...]
#
# Fires <event> to every subscribed provider. Extra key=value pairs are
# passed to each provider as the payload. Always returns 0.
#
# Example:
#   notify_event deploy.success stack=my-stack env=prod duration=42s
notify_event() {
  local event="$1"
  shift || true

  notify_load_config || true

  # In dry-run mode, just echo what would be sent
  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[notify:dry-run] event=$event payload=$*"
    return 0
  fi

  # Slack
  if [ -n "${SLACK_WEBHOOK:-}" ] && \
     _notify_provider_subscribed "${SLACK_EVENTS:-}" "$event"; then
    notify_slack_send "$SLACK_WEBHOOK" "$event" "$@" || \
      warn "Slack notification failed for event=$event (continuing)"
  fi

  # Discord
  if [ -n "${DISCORD_WEBHOOK:-}" ] && \
     _notify_provider_subscribed "${DISCORD_EVENTS:-}" "$event"; then
    notify_discord_send "$DISCORD_WEBHOOK" "$event" "$@" || \
      warn "Discord notification failed for event=$event (continuing)"
  fi

  # Generic webhook
  if [ -n "${WEBHOOK_URL:-}" ] && \
     _notify_provider_subscribed "${WEBHOOK_EVENTS:-}" "$event"; then
    notify_webhook_send "$WEBHOOK_URL" "$event" "$@" || \
      warn "Webhook notification failed for event=$event (continuing)"
  fi

  return 0
}

# notify_test <provider>
#
# Sends a deploy.success test event to the named provider. Used by
# `strut notify test <provider>`.
notify_test() {
  local provider="${1:-}"
  notify_load_config || true

  case "$provider" in
    slack)
      [ -n "${SLACK_WEBHOOK:-}" ] || fail "SLACK_WEBHOOK not configured in notifications.conf"
      notify_slack_send "$SLACK_WEBHOOK" "test.ping" \
        stack=test env=test message="strut notify test message"
      ;;
    discord)
      [ -n "${DISCORD_WEBHOOK:-}" ] || fail "DISCORD_WEBHOOK not configured in notifications.conf"
      notify_discord_send "$DISCORD_WEBHOOK" "test.ping" \
        stack=test env=test message="strut notify test message"
      ;;
    webhook)
      [ -n "${WEBHOOK_URL:-}" ] || fail "WEBHOOK_URL not configured in notifications.conf"
      notify_webhook_send "$WEBHOOK_URL" "test.ping" \
        stack=test env=test message="strut notify test message"
      ;;
    "")
      fail "Usage: strut notify test <slack|discord|webhook>"
      ;;
    *)
      fail "Unknown provider: $provider (slack|discord|webhook)"
      ;;
  esac
}

# _notify_payload_json <event> [key=value ...]
#
# Builds a minimal JSON payload from the event name and key=value pairs.
# Only explicit keys are included — never dumps env, protecting against
# accidental secret leakage (related to #25).
_notify_payload_json() {
  local event="$1"
  shift || true

  local payload="{\"event\":\"$event\""
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    # Escape double quotes and backslashes in value
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    payload+=",\"$key\":\"$val\""
  done
  payload+="}"
  echo "$payload"
}
