#!/usr/bin/env bash
# ==================================================
# cmd_rollback.sh — Rollback command handler
# ==================================================
# Provides:
#   cmd_rollback [--list] [--dry-run] (reads CMD_* context variables)

set -euo pipefail

_usage_rollback() {
  echo ""
  echo "Usage: strut <stack> rollback [--env <name>] [--list] [--dry-run]"
  echo "       strut <stack> rollback diff <a> <b> [--json]"
  echo ""
  echo "Roll back to the previous deploy snapshot, list snapshots, or diff"
  echo "two historical snapshots for post-incident forensics."
  echo ""
  echo "Flags:"
  echo "  --list               List available rollback points"
  echo "  --dry-run            Show what would be restored without making changes"
  echo ""
  echo "Diff refs accept: snapshot basename, HEAD (latest), or HEAD~N (Nth older)."
  echo ""
  echo "Snapshots are automatically saved before each deploy."
  echo "Retention: last ${ROLLBACK_RETENTION:-5} snapshots (configurable via ROLLBACK_RETENTION in strut.conf)."
  echo ""
  echo "Examples:"
  echo "  strut my-stack rollback --env prod"
  echo "  strut my-stack rollback --env prod --list"
  echo "  strut my-stack rollback --env prod --dry-run"
  echo "  strut my-stack rollback diff HEAD~1 HEAD"
  echo "  strut my-stack rollback diff 20260420-091500 HEAD --json"
  echo ""
}

# _rollback_diff <stack> <ref-a> <ref-b> [--json]
#
# Renders a structured diff of the images each snapshot captured.
# Exit codes match `strut diff`:
#   0 — snapshots are equivalent (no image changes)
#   1 — snapshots differ
#   2 — error resolving a ref
_rollback_diff() {
  local stack="$1"; shift
  local ref_a="" ref_b=""
  local json_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)    json_mode=true; shift ;;
      --help|-h) _usage_rollback; return 0 ;;
      *)
        if [ -z "$ref_a" ]; then ref_a="$1"
        elif [ -z "$ref_b" ]; then ref_b="$1"
        else
          fail "Unexpected arg: $1 (usage: rollback diff <a> <b>)"
          return 2
        fi
        shift ;;
    esac
  done

  if [ -z "$ref_a" ] || [ -z "$ref_b" ]; then
    _usage_rollback
    fail "rollback diff requires two snapshot refs"
    return 2
  fi

  # Ensure diff helpers are available when cmd_rollback is sourced standalone.
  # Guarded so tests can override _rollback_dir after sourcing without us
  # clobbering it on re-entry.
  declare -F rollback_get_latest_snapshot >/dev/null || source "$LIB/rollback.sh"
  declare -F diff_image_pairs            >/dev/null || source "$LIB/diff.sh"

  local file_a file_b
  file_a=$(rollback_resolve_ref "$stack" "$ref_a") || return 2
  file_b=$(rollback_resolve_ref "$stack" "$ref_b") || return 2

  local pairs_a pairs_b
  pairs_a=$(rollback_snapshot_image_pairs "$file_a")
  pairs_b=$(rollback_snapshot_image_pairs "$file_b")

  # Treat <b> as "new" — operators read "HEAD~1 → HEAD" as "from old to new".
  local image_diff
  image_diff=$(diff_image_pairs "$pairs_b" "$pairs_a")

  local has_changes=0
  [ -n "$image_diff" ] && has_changes=1

  local base_a base_b
  base_a=$(basename "$file_a" .json)
  base_b=$(basename "$file_b" .json)

  if [ "$json_mode" = "true" ]; then
    OUTPUT_MODE=json
    out_json_object
      out_json_field "stack" "$stack"
      out_json_field "from" "$base_a"
      out_json_field "to" "$base_b"
      out_json_field_raw "has_changes" "$([ "$has_changes" -eq 1 ] && echo true || echo false)"
      _diff_render_section_json "images" "$image_diff"
    out_json_close_object
    out_json_newline
  else
    if [ "$has_changes" -eq 0 ]; then
      ok "Snapshots are identical: $base_a == $base_b"
    else
      echo ""
      echo "Rollback diff for $stack: $base_a → $base_b"
      _diff_render_section_text "Images" "$image_diff"
      echo ""
    fi
  fi

  [ "$has_changes" -eq 1 ] && return 1
  return 0
}

cmd_rollback() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"

  # Subcommand dispatch — `rollback diff …` runs independently of the
  # restore path (no env file or compose required).
  if [ "${1:-}" = "diff" ]; then
    shift
    _rollback_diff "$stack" "$@"
    return $?
  fi

  # Parse rollback-specific flags
  local list_mode=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --list|-l) list_mode=true; shift ;;
      *) shift ;;
    esac
  done

  declare -F rollback_get_latest_snapshot >/dev/null || source "$LIB/rollback.sh"

  if $list_mode; then
    rollback_list_snapshots "$stack"
    return 0
  fi

  # Find the latest snapshot
  local snapshot_file
  snapshot_file=$(rollback_get_latest_snapshot "$stack")

  if [ -z "$snapshot_file" ] || [ ! -f "$snapshot_file" ]; then
    fail "No rollback snapshots found for stack: $stack (deploy at least once first)"
  fi

  # Dry-run: show what would be restored
  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for rollback:${NC}"

    if command -v jq &>/dev/null; then
      local timestamp service_count
      timestamp=$(jq -r '.timestamp' "$snapshot_file")
      service_count=$(jq -r '.service_count' "$snapshot_file")
      echo "  Snapshot: $(basename "$snapshot_file" .json)"
      echo "  Timestamp: $timestamp"
      echo "  Services: $service_count"
      echo ""

      jq -r '.services | to_entries[] | "  [DRY-RUN] Pull \(.key) → \(.value.image)"' "$snapshot_file"
    fi

    run_cmd "Stop current containers" echo "compose down --remove-orphans"
    run_cmd "Start services with restored images" echo "compose up -d --remove-orphans"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Actual rollback
  validate_env_file "$env_file"
  set -a; source "$env_file"; set +a

  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")

  rollback_restore_snapshot "$stack" "$compose_cmd" "$snapshot_file"
}
