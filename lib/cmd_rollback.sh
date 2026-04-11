#!/usr/bin/env bash
# ==================================================
# cmd_rollback.sh — Rollback command handler
# ==================================================
# Provides:
#   cmd_rollback <stack> <stack_dir> <env_file> <env_name> <services> [--list] [--dry-run]

set -euo pipefail

_usage_rollback() {
  echo ""
  echo "Usage: strut <stack> rollback [--env <name>] [--list] [--dry-run]"
  echo ""
  echo "Roll back to the previous deploy snapshot."
  echo ""
  echo "Flags:"
  echo "  --list               List available rollback points"
  echo "  --dry-run            Show what would be restored without making changes"
  echo ""
  echo "Snapshots are automatically saved before each deploy."
  echo "Retention: last ${ROLLBACK_RETENTION:-5} snapshots (configurable via ROLLBACK_RETENTION in strut.conf)."
  echo ""
  echo "Examples:"
  echo "  strut my-stack rollback --env prod"
  echo "  strut my-stack rollback --env prod --list"
  echo "  strut my-stack rollback --env prod --dry-run"
  echo ""
}

cmd_rollback() {
  local stack="$1"
  local stack_dir="$2"
  local env_file="$3"
  local env_name="$4"
  local services="$5"
  shift 5

  # Parse rollback-specific flags
  local list_mode=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --list|-l) list_mode=true; shift ;;
      *) shift ;;
    esac
  done

  source "$LIB/rollback.sh"

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
