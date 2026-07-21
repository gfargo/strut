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
#   history_git_sha  — short SHA of the deployed repo (best-effort)
#   history_actor    — CI-aware actor identification (best-effort)
#   history_show     — full detail for one release/deploy/rollback entry

set -euo pipefail

# history_git_sha [dir]
#
# Short SHA of the git repo at <dir> (defaults to $CLI_ROOT). Best-effort —
# echoes "unknown" rather than failing, since a broken git lookup must never
# abort a deploy.
history_git_sha() {
  local dir="${1:-${CLI_ROOT:-.}}"
  git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# history_actor
#
# Best-effort actor identification. Prefers CI-provided identity over the
# invoking shell user, so a deploy triggered by a CI pipeline attributes to
# the human/bot that triggered it, not the runner's service account.
history_actor() {
  echo "${GITHUB_ACTOR:-${GITLAB_USER_LOGIN:-${CI_COMMIT_AUTHOR:-${USER:-$(whoami 2>/dev/null || echo unknown)}}}}"
}

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
  local user
  user=$(history_actor 2>/dev/null) || user="${USER:-unknown}"
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

# history_list_releases <stack_dir> [--limit N] [--json] [--env <name>]
#
# Release-centric view over the same JSONL store as history_list: only
# "deploy" and "release" actions, newest first, with the release-specific
# columns (mode, git SHA, release ID) that pair with `rollback <id>`.
# Requires jq — release detail (mode/sha/release_id) isn't reliably
# extractable without it, and jq is already a hard requirement for the rest
# of the rollback family (rollback_restore_snapshot, rollback diff).
history_list_releases() {
  local stack_dir="$1"; shift
  local limit=10
  local json_mode=false
  local env_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --json)  json_mode=true; shift ;;
      --env)   env_filter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local hist_file="$stack_dir/.deploy-history.jsonl"

  if [ ! -f "$hist_file" ]; then
    if [ "$json_mode" = "true" ]; then echo "[]"; else echo "No releases recorded yet."; fi
    return 0
  fi

  if ! command -v jq &>/dev/null; then
    if [ "$json_mode" = "true" ]; then
      echo "[]"
    else
      echo "jq is required to render 'releases' output (install with: brew install jq)"
    fi
    return 0
  fi

  local jq_filter='select(.action == "deploy" or .action == "release")'
  [ -n "$env_filter" ] && jq_filter="${jq_filter} | select(.env == \"$(json_escape "$env_filter")\")"

  local entries
  entries=$(jq -c "$jq_filter" "$hist_file" 2>/dev/null | tail -n "$limit" | sed '1!G;h;$!d')

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

  if [ -z "$entries" ]; then
    echo "No releases recorded yet."
    return 0
  fi

  printf '%-21s %-8s %-9s %-9s %-8s %-10s %s\n' "TIMESTAMP" "MODE" "OUTCOME" "SHA" "ENV" "RELEASE_ID" "USER"
  local line ts mode outcome sha env release_id user
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ts=$(echo "$line" | jq -r '.timestamp // "?"')
    mode=$(echo "$line" | jq -r '.mode // "-"')
    outcome=$(echo "$line" | jq -r '.outcome // "?"')
    sha=$(echo "$line" | jq -r '.git_sha // "-"')
    env=$(echo "$line" | jq -r '.env // "-"')
    release_id=$(echo "$line" | jq -r '.release_id // "-"')
    # .actor (CI-aware, set by the vps_release "release" record) takes
    # precedence over .user (the executing shell's identity — accurate for
    # local deploys, but just the VPS service account for remote ones).
    user=$(echo "$line" | jq -r '.actor // .user // "?"')
    printf '%-21s %-8s %-9s %-9s %-8s %-10s %s\n' "$ts" "$mode" "$outcome" "$sha" "$env" "$release_id" "$user"
  done <<< "$entries"
}

# history_show <stack_dir> <id> [--json]
#
# Full detail for one release/deploy entry, matched by release_id (falls
# back to an exact timestamp match). Joins with the paired rollback
# snapshot's image data when rollback_snapshot_image_pairs is available
# (source lib/rollback.sh before calling this for image detail) and the
# snapshot file still exists. NOTE: the rollback snapshot is saved
# *before* the new images are pulled/started, so these are the pre-release
# images this release would revert to (via `rollback <id>`) — not the
# images this release actually shipped.
#
# Best-effort by design, matching the rest of this module: a missing jq or
# a missing snapshot degrades output rather than failing loudly, except
# "no matching entry" which is a genuine not-found (exit 1).
history_show() {
  local stack_dir="$1" id="$2"; shift 2
  local json_mode=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=true; shift ;;
      *) shift ;;
    esac
  done

  local hist_file="$stack_dir/.deploy-history.jsonl"
  local line=""

  if [ -f "$hist_file" ] && command -v jq &>/dev/null; then
    line=$(jq -c --arg id "$id" \
      'select((.release_id // "") == $id or (.timestamp // "") == $id)' \
      "$hist_file" 2>/dev/null | tail -n 1) || true
  fi

  # Fall back to the snapshot's own metadata when no history entry
  # references this release ID — e.g. deploys recorded before this field
  # existed, or a release_id that was empty at record-time (rollback
  # snapshot skipped because there were no running containers yet).
  if [ -z "$line" ]; then
    local snap="$stack_dir/.rollback/${id}.json"
    if [ -f "$snap" ] && command -v jq &>/dev/null; then
      line=$(jq -c --arg id "$id" \
        '{release_id: $id, timestamp: (.timestamp // "?"), action: "release", outcome: "unknown", env: (.env // "-"), mode: "-", git_sha: "-", user: "-"}' \
        "$snap" 2>/dev/null) || true
    fi
  fi

  if [ -z "$line" ]; then
    if [ "$json_mode" = "true" ]; then echo "null"; else echo "No release found matching: $id"; fi
    return 1
  fi

  local release_id=""
  if command -v jq &>/dev/null; then
    release_id=$(echo "$line" | jq -r '.release_id // empty' 2>/dev/null) || true
  fi
  [ -z "$release_id" ] && release_id="$id"

  local images_json="[]"
  local snapshot_file="$stack_dir/.rollback/${release_id}.json"
  if [ -f "$snapshot_file" ] && declare -F rollback_snapshot_image_pairs >/dev/null && command -v jq &>/dev/null; then
    images_json=$(rollback_snapshot_image_pairs "$snapshot_file" 2>/dev/null | awk -F'\x1f' '
      BEGIN { printf "[" }
      { if (NR>1) printf ","; printf "{\"service\":\"%s\",\"image\":\"%s\"}", $1, $2 }
      END { printf "]" }
    ')
    [ -z "$images_json" ] && images_json="[]"
  fi

  if [ "$json_mode" = "true" ]; then
    if command -v jq &>/dev/null; then
      echo "$line" | jq -c --argjson images "$images_json" '. + {rollback_images: $images}'
    else
      echo "$line"
    fi
    return 0
  fi

  if command -v jq &>/dev/null; then
    echo ""
    echo "Release: $release_id"
    echo "  Timestamp: $(echo "$line" | jq -r '.timestamp // "?"')"
    echo "  Action:    $(echo "$line" | jq -r '.action // "?"')"
    echo "  Outcome:   $(echo "$line" | jq -r '.outcome // "?"')"
    echo "  Env:       $(echo "$line" | jq -r '.env // "-"')"
    echo "  Mode:      $(echo "$line" | jq -r '.mode // "-"')"
    echo "  Git SHA:   $(echo "$line" | jq -r '.git_sha // "-"')"
    echo "  Actor:     $(echo "$line" | jq -r '.actor // .user // "?"')"
    if [ "$images_json" != "[]" ]; then
      echo "  Rollback-to images (pre-release state):"
      echo "$images_json" | jq -r '.[] | "    \(.service) -> \(.image)"'
    fi
    echo ""
  else
    echo "$line"
  fi
}
