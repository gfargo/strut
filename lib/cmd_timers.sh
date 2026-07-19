#!/usr/bin/env bash
# ==================================================
# lib/cmd_timers.sh — strut <stack> timers dispatch
# ==================================================
# Requires: lib/utils.sh, lib/topology.sh, lib/timers.sh sourced first
#
# Timers run on the host the stack is actually deployed to, so — exactly
# like cmd_status/cmd_health — this dispatches over SSH when the stack maps
# to a VPS_HOST we're not already on, rather than inspecting the (empty)
# local systemd.

set -euo pipefail

_usage_timers() {
  echo ""
  echo "Usage: strut <stack> timers [list|install|remove] [--env <name>] [--json] [--dry-run]"
  echo ""
  echo "Manage systemd timers declared in stacks/<stack>/timers.conf."
  echo ""
  echo "Commands:"
  echo "  list      Show configured timers with next/last run (default)"
  echo "  install   Render + install/enable timer units (idempotent)"
  echo "  remove    Disable and remove all strut-managed timer units for this stack"
  echo ""
  echo "Timers run on the host the stack deploys to — this command dispatches"
  echo "over SSH the same way 'status' does. Installed automatically at the"
  echo "end of a successful deploy; a stack with no timers.conf is a no-op."
  echo ""
  echo "Examples:"
  echo "  strut media timers --env prod"
  echo "  strut media timers install --env prod"
  echo "  strut media timers remove --env prod"
  echo "  strut media timers list --json --env prod"
  echo ""
}

# cmd_timers [list|install|remove] (reads CMD_*)
cmd_timers() {
  local subcmd="${1:-list}"
  shift || true

  case "$subcmd" in
    list|install|remove) ;;
    help|--help|-h) _usage_timers; return 0 ;;
    *) _usage_timers; fail "Unknown timers subcommand: $subcmd"; return 1 ;;
  esac

  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  [ -f "$env_file" ] && validate_env_file "$env_file"

  # Prefer remote execution for stacks that map to a VPS host, so timers
  # reflect (and mutate) the real remote systemd instead of the local one.
  if should_dispatch_remote; then
    local remote_args="timers $subcmd"
    [ -n "${CMD_JSON:-}" ] && remote_args="$remote_args --json"
    run_remote_strut "$stack" "$env_name" "$remote_args"
    return $?
  fi

  case "$subcmd" in
    list)    timers_list "$stack" "$stack_dir" ;;
    install) timers_install "$stack" "$stack_dir" ;;
    remove)  timers_remove "$stack" "$stack_dir" ;;
  esac
}
