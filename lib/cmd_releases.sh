#!/usr/bin/env bash
# ==================================================
# cmd_releases.sh — `strut <stack> releases [show <id>]` command handler
# ==================================================
# Release-centric view over the same `.deploy-history.jsonl` store as
# `strut <stack> history`: only deploy/release actions, enriched with git
# SHA, deploy mode, and the release_id that pairs with
# `strut <stack> rollback <id>` (both share the rollback snapshot ID
# space — release_id IS the snapshot basename).

set -euo pipefail

_usage_releases() {
  echo ""
  echo "Usage: strut <stack> releases [--env <name>] [--limit N] [--json]"
  echo "       strut <stack> releases show <id> [--env <name>] [--json]"
  echo ""
  echo "List past deploys/releases (newest first) or show full detail for one,"
  echo "including git SHA, deploy mode, and per-service image tags."
  echo ""
  echo "Flags:"
  echo "  --env <name>   Environment (used to resolve VPS dispatch)"
  echo "  --limit N      Number of entries to show (default: 10)"
  echo "  --json         Output as JSON"
  echo ""
  echo "<id> accepts: release ID (rollback snapshot basename), HEAD (latest),"
  echo "or HEAD~N (Nth older) — the same refs 'rollback' resolves, so you can"
  echo "pick a release here and revert to it with: strut <stack> rollback <id>"
  echo ""
  echo "Examples:"
  echo "  strut my-stack releases --env prod"
  echo "  strut my-stack releases --env prod --json --limit 20"
  echo "  strut my-stack releases show HEAD --env prod"
  echo "  strut my-stack releases show 20260420-091500 --env prod --json"
  echo ""
}

# cmd_releases [show <id>] [--limit N] [--json] (reads CMD_*)
cmd_releases() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  local limit=10
  local json_mode=false
  local show_mode=false
  local show_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      show)
        show_mode=true
        shift
        show_id="${1:-}"
        [ -n "$show_id" ] && shift
        ;;
      --limit) limit="$2"; shift 2 ;;
      --json)  json_mode=true; shift ;;
      --help|-h) _usage_releases; return 0 ;;
      *) shift ;;
    esac
  done

  if [ "$show_mode" = "true" ] && [ -z "$show_id" ]; then
    _usage_releases
    fail "releases show requires an <id> (release ID, HEAD, or HEAD~N)"
    return 2
  fi

  # Prefer remote execution for VPS-mapped stacks — history/rollback
  # snapshots live with the deploy dir wherever release/deploy actually
  # ran, same dispatch pattern as `strut <stack> history` / `rollback`.
  [ -f "$env_file" ] && validate_env_file "$env_file" 2>/dev/null
  if should_dispatch_remote; then
    local remote_args="releases"
    if [ -n "$show_id" ]; then
      remote_args="$remote_args show $show_id"
    else
      remote_args="$remote_args --limit $limit"
    fi
    [ "$json_mode" = "true" ] && remote_args="$remote_args --json"
    run_remote_strut "$stack" "$env_name" "$remote_args"
    return $?
  fi

  declare -F history_list_releases >/dev/null || source "$LIB/history.sh"

  if [ -z "$show_id" ]; then
    local args=(--limit "$limit")
    [ "$json_mode" = "true" ] && args+=(--json)
    history_list_releases "$stack_dir" "${args[@]}"
    return 0
  fi

  # `show` — resolve HEAD / HEAD~N / basename through the same ref
  # resolver rollback uses, so `releases show HEAD` and `rollback HEAD`
  # always agree on which snapshot "HEAD" means. Falls back to the literal
  # id when resolution fails (no snapshots dir yet, or a ref that predates
  # any rollback snapshot) — history_show still has a shot at the JSONL
  # entry directly.
  declare -F rollback_resolve_ref >/dev/null || source "$LIB/rollback.sh"
  local resolved_id="$show_id"
  local resolved_file
  if resolved_file=$(rollback_resolve_ref "$stack" "$show_id" 2>/dev/null); then
    resolved_id=$(basename "$resolved_file" .json)
  fi

  local args=("$resolved_id")
  [ "$json_mode" = "true" ] && args+=(--json)
  history_show "$stack_dir" "${args[@]}"
}
