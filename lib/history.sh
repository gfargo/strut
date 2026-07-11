#!/usr/bin/env bash
# ==================================================
# lib/history.sh — Deploy/rollback audit trail
# ==================================================
# Append-only JSONL history per stack: <stack_dir>/.deploy-history.jsonl
#
# Recording always happens on whichever machine actually performs the
# action. For VPS-mapped stacks, release/deploy/rollback already dispatch
# their real work onto the remote host (should_dispatch_remote /
# run_remote_strut, or vps_release's own SSH steps), so a plain local file
# write there naturally lands the history file inside the deploy dir on
# that host — it survives VPS reboots as ordinary disk state, and reading
# it back (cmd_history.sh) uses the same remote-dispatch pattern.
#
# Functions:
#   history_record  — append one entry (best-effort, never fails the caller)
#   history_list     — read + format entries for `strut <stack> history`

set -euo pipefail

# history_record <stack_dir> <action> <outcome> [key=value ...] [key:=rawvalue ...]
#
# Always sets: timestamp, stack, action, user, outcome.
# Extra fields: `key=value` is written as an escaped JSON string;
# `key:=value` is written raw/unquoted (caller-guaranteed valid JSON —
# for numbers and arrays, e.g. duration_s:=45 or flags:='["--force-clean"]').
#
# Best-effort by design: a broken history write must never fail a deploy.
history_record() {
  local stack_dir="$1" action="$2" outcome="$3"
  shift 3

  local hist_file="$stack_dir/.deploy-history.jsonl"
  mkdir -p "$stack_dir" 2>/dev/null || return 0

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || return 0
  local user="${USER:-$(whoami 2>/dev/null || echo unknown)}"
  local stack
  stack=$(basename "$stack_dir")

  local line
  line="{\"timestamp\":\"$(json_escape "$ts")\",\"stack\":\"$(json_escape "$stack")\",\"action\":\"$(json_escape "$action")\",\"user\":\"$(json_escape "$user")\",\"outcome\":\"$(json_escape "$outcome")\""

  local kv key val
  for kv in "$@"; do
    if [[ "$kv" == *":="* ]]; then
      key="${kv%%:=*}"
      val="${kv#*:=}"
      line="${line},\"$(json_escape "$key")\":${val}"
    else
      key="${kv%%=*}"
      val="${kv#*=}"
      line="${line},\"$(json_escape "$key")\":\"$(json_escape "$val")\""
    fi
  done
  line="${line}}"

  echo "$line" >> "$hist_file" 2>/dev/null || true
}

# history_list <stack_dir> [--limit N] [--json]
#
# Prints recent history entries, most recent first. Text mode renders a
# compact table (via jq if available, else raw JSONL); --json emits a
# JSON array.
history_list() {
  local stack_dir="$1"; shift
  local limit=10
  local json_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --json)  json_mode=true; shift ;;
      *) shift ;;
    esac
  done

  local hist_file="$stack_dir/.deploy-history.jsonl"

  if [ ! -f "$hist_file" ]; then
    if [ "$json_mode" = "true" ]; then
      echo "[]"
    else
      echo "No history recorded yet."
    fi
    return 0
  fi

  # Reverse to most-recent-first with a portable sed idiom (tac/tail -r are
  # GNU/BSD-specific respectively — this runs on both macOS and Linux VPS
  # hosts via remote dispatch).
  local entries
  entries=$(tail -n "$limit" "$hist_file" | sed '1!G;h;$!d')

  if [ "$json_mode" = "true" ]; then
    printf '['
    local first=true line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if [ "$first" = "true" ]; then first=false; else printf ','; fi
      printf '%s' "$line"
    done <<< "$entries"
    printf ']\n'
    return 0
  fi

  if command -v jq &>/dev/null; then
    printf '%-21s %-9s %-9s %-10s %s\n' "TIMESTAMP" "ACTION" "OUTCOME" "USER" "ENV"
    local line ts action outcome user env
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      ts=$(echo "$line" | jq -r '.timestamp // "?"')
      action=$(echo "$line" | jq -r '.action // "?"')
      outcome=$(echo "$line" | jq -r '.outcome // "?"')
      user=$(echo "$line" | jq -r '.user // "?"')
      env=$(echo "$line" | jq -r '.env // "-"')
      printf '%-21s %-9s %-9s %-10s %s\n' "$ts" "$action" "$outcome" "$user" "$env"
    done <<< "$entries"
  else
    echo "$entries"
  fi
}
