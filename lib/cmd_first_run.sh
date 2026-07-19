#!/usr/bin/env bash
# ==================================================
# lib/cmd_first_run.sh — Inspect/repair the first_run lifecycle hook
# ==================================================
# Requires: lib/utils.sh, lib/hooks.sh sourced first
#
# Provides:
#   cmd_first_run [--force|--status] (reads CMD_* context variables)

set -euo pipefail

_usage_first_run() {
  echo ""
  echo "Usage: strut <stack> first-run [--status|--force] [--env <name>]"
  echo ""
  echo "Inspect or repair the stack's first_run lifecycle hook. The"
  echo "hooks/first_run.sh script normally runs once per stack — success"
  echo "writes .strut-initialized so it never re-runs; failure leaves no"
  echo "marker so it retries on the next deploy."
  echo ""
  echo "Bare 'first-run' (no flag) is read-only and behaves like --status."
  echo ""
  echo "Flags:"
  echo "  --status      Show whether the marker exists and its timestamp (default)"
  echo "  --force       Remove the marker and re-run the hook now (repair);"
  echo "                rewrites the marker only if the hook succeeds"
  echo "  --dry-run     Preview --force without touching the marker or running the hook"
  echo ""
  echo "Examples:"
  echo "  strut my-stack first-run --env prod"
  echo "  strut my-stack first-run --force --env prod"
  echo ""
}

# cmd_first_run [--force|--status] (reads CMD_*)
cmd_first_run() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  local mode="status"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)   mode="force"; shift ;;
      --status)  mode="status"; shift ;;
      --help|-h) _usage_first_run; return 0 ;;
      *) shift ;;
    esac
  done

  [ -f "$env_file" ] && validate_env_file "$env_file" 2>/dev/null

  # Prefer remote execution for stacks that map to a VPS host — the marker
  # lives on the VPS, so status/force must inspect and mutate it there.
  if should_dispatch_remote; then
    local remote_args="first-run --$mode"
    run_remote_strut "$stack" "$env_name" "$remote_args"
    return $?
  fi

  if [ "$mode" = "status" ]; then
    first_run_status "$stack_dir"
    return 0
  fi

  # mode = force
  if [ "${DRY_RUN:-}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for first-run --force:${NC}"
    local hook_file
    if hook_file=$(_first_run_hook_file "$stack_dir"); then
      echo "  Would remove marker: $(_first_run_marker_path "$stack_dir")"
      echo "  Would run hook: $hook_file"
    else
      echo "  No first_run hook found — nothing to do"
    fi
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  fire_first_run_hook "$stack_dir" force
}
