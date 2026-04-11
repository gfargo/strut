#!/usr/bin/env bash
# ==================================================
# cmd_drift.sh — Drift detection command handler
# ==================================================

set -euo pipefail

_usage_drift() {
  echo ""
  echo "Usage: strut <stack> drift [--env <name>] <subcommand> [options]"
  echo ""
  echo "Configuration drift detection between git-tracked and VPS runtime files."
  echo ""
  echo "Subcommands:"
  echo "  detect                 Detect configuration drift"
  echo "  report [--json]        Generate drift detection report"
  echo "  diff <file>            Show detailed diff for a specific file"
  echo "  fix [--dry-run]        Fix drift by applying git-tracked config"
  echo "  monitor [--auto-fix]   Monitor for drift (for cron jobs)"
  echo "  history [--limit N]    Show drift detection history"
  echo "  auto-fix enable|disable|status   Manage automatic drift fixing"
  echo ""
  echo "Examples:"
  echo "  strut my-stack drift detect --env prod"
  echo "  strut my-stack drift report --env prod --json"
  echo "  strut my-stack drift diff docker-compose.yml"
  echo "  strut my-stack drift fix --env prod --dry-run"
  echo "  strut my-stack drift history --limit 20"
  echo ""
}

# cmd_drift <stack> <env_file> <env_name> <json_flag> [subcommand] [args...]
cmd_drift() {
  local stack="$1"
  local env_file="$2"
  local env_name="$3"
  local json_flag="$4"
  shift 4

  # Parse: first positional is the subcommand, rest are subcommand-specific
  local target="${1:-detect}"
  shift || true

  # Source drift library
  source "$LIB/drift.sh"

  # Most drift commands need ENV_FILE (except diff and history)
  if [[ "$target" != "history" && "$target" != "diff" ]]; then
    validate_env_file "$env_file"
  fi

  case "$target" in
    detect)
      drift_detect "$stack" "$env_name"
      ;;
    report)
      drift_report "$stack" "$env_name" "$json_flag"
      ;;
    diff)
      local diff_file="${1:-}"
      [ -z "$diff_file" ] && fail "Usage: strut $stack drift diff <file>"
      drift_diff "$stack" "$diff_file"
      ;;
    fix)
      # Pass --dry-run if global DRY_RUN is set, or if user passed it as subcommand arg
      local fix_flag="${1:-}"
      if [ "$DRY_RUN" = "true" ] && [ "$fix_flag" != "--dry-run" ]; then
        fix_flag="--dry-run"
      fi
      drift_fix "$stack" "$env_name" "$fix_flag"
      ;;
    monitor)
      drift_monitor "$stack" "$env_name" "${1:-}"
      ;;
    history)
      local limit_flag=""
      local limit_value=""
      while [[ $# -gt 0 ]]; do
        case $1 in
          --limit) limit_flag="--limit"; limit_value="${2:-10}"; shift 2 ;;
          *) shift ;;
        esac
      done
      drift_history "$stack" "$limit_flag" "$limit_value"
      ;;
    auto-fix)
      local autofix_cmd="${1:-}"
      source "$LIB/drift/autofix.sh"
      case "$autofix_cmd" in
        enable)  drift_autofix_enable "$stack" "$env_name" ;;
        disable) drift_autofix_disable "$stack" ;;
        status)  drift_autofix_status "$stack" ;;
        *) fail "Unknown auto-fix subcommand: $autofix_cmd (enable|disable|status)" ;;
      esac
      ;;
    *)
      fail "Unknown drift command: $target

Available commands:
  detect                                Detect configuration drift
  report [--json]                       Generate drift detection report
  fix [--dry-run]                       Fix configuration drift
  monitor [--auto-fix]                  Monitor for drift (for cron)
  history [--limit N]                   Show drift detection history
  auto-fix enable                       Enable automatic drift fixing
  auto-fix disable                      Disable automatic drift fixing
  auto-fix status                       Show auto-fix status"
      ;;
  esac
}
