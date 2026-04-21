#!/usr/bin/env bash
# ==================================================
# lib/cmd_lock.sh — `strut <stack> lock <status|release>` handler
# ==================================================
# Introspection and manual management of deploy locks.

set -euo pipefail

_usage_lock() {
  cat <<'EOF'

Usage: strut <stack> lock <status|release> [--env <name>] [--force] [--remote]

Inspect or manually manage deploy concurrency locks. Locks are acquired
automatically by `deploy` and `release` to prevent concurrent deploys
against the same stack+env.

Subcommands:
  status       Show lock state (local + remote if VPS_HOST is set)
  release      Release lock held by current process
                 --force   Break the lock even if another process holds it

Flags:
  --env <name>   Environment (reads .<name>.env)
  --remote       Act only on the remote VPS lock
  --local        Act only on the local lock
  --help, -h     Show this help

Exit codes:
  0  Lock is held (status) or release succeeded
  1  Lock is not held (status) or release failed

Examples:
  strut my-stack lock status --env prod
  strut my-stack lock release --env prod --force
  strut my-stack deploy --env prod --force-unlock   # break stale lock + deploy

EOF
}

cmd_lock() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="${CMD_ENV_NAME:-default}"

  local sub="${1:-}"
  shift || true

  local force=false
  local scope=both
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)  force=true; shift ;;
      --remote) scope=remote; shift ;;
      --local)  scope=local; shift ;;
      --help|-h) _usage_lock; return 0 ;;
      *) fail "Unknown flag: $1"; return 1 ;;
    esac
  done

  # Best-effort load env (for VPS_HOST); missing env file is only fatal for remote scope.
  if [ -f "$env_file" ]; then
    set -a; source "$env_file"; set +a
  fi

  case "$sub" in
    status)
      local held=0
      if [ "$scope" != "remote" ]; then
        if lock_status_local "$stack" "$env_name"; then
          held=1
        fi
      fi
      if [ "$scope" != "local" ] && [ -n "${VPS_HOST:-}" ]; then
        echo ""
        echo "Remote lock on $VPS_HOST:"
        if lock_status_remote "$stack" "$env_name"; then
          held=1
        else
          echo "  not held"
        fi
      fi
      [ "$held" -eq 1 ] && return 0 || return 1
      ;;

    release)
      if [ "$scope" != "remote" ]; then
        if [ "$force" = "true" ]; then
          lock_force_break_local "$stack" "$env_name"
          ok "Local lock released (forced)"
        else
          lock_release_local "$stack" "$env_name"
          ok "Local lock released"
        fi
      fi
      if [ "$scope" != "local" ] && [ -n "${VPS_HOST:-}" ]; then
        lock_release_remote "$stack" "$env_name"
        ok "Remote lock released on $VPS_HOST"
      fi
      return 0
      ;;

    ""|-h|--help)
      _usage_lock
      return 0
      ;;

    *)
      fail "Unknown lock subcommand: $sub (use 'status' or 'release')"
      return 1
      ;;
  esac
}
