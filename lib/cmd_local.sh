#!/usr/bin/env bash
# ==================================================
# cmd_local.sh — Local/prod/staging/dev environment command handler
# ==================================================
# Parses its own positional args from CMD_ARGS.

set -euo pipefail

_usage_local() {
  echo ""
  echo "Usage: strut <stack> local <command> [options]"
  echo ""
  echo "Local development environment commands."
  echo ""
  echo "Commands:"
  echo "  start [--services <profile>]       Start stack locally"
  echo "  stop                               Stop local stack"
  echo "  reset                              Reset local environment"
  echo "  sync-env --from <env>              Sync env vars from remote"
  echo "  sync-db --from <env> [target]      Sync database from remote"
  echo "  logs [--follow]                    Tail local logs"
  echo "  test                               Run local smoke tests"
  echo "  debug <cmd> <service> [options]    Debug local containers"
  echo ""
  echo "Examples:"
  echo "  strut my-stack local start"
  echo "  strut my-stack local start --services full"
  echo "  strut my-stack local stop"
  echo "  strut my-stack local sync-db --from prod postgres"
  echo "  strut my-stack local logs --follow"
  echo ""
}

# cmd_local_env <stack> <env_prefix> [actual_command] [args...]
cmd_local_env() {
  local stack="$1"
  local env_prefix="$2"
  shift 2

  local actual_command="${1:-start}"
  shift || true

  # Override ENV_FILE based on prefix
  local env_file
  case "$env_prefix" in
    local)   env_file="$CLI_ROOT/stacks/$stack/.env.local" ;;
    prod)    env_file="$CLI_ROOT/.prod.env" ;;
    staging) env_file="$CLI_ROOT/.staging.env" ;;
    dev)     env_file="$CLI_ROOT/.dev.env" ;;
  esac

  # Check if this is a debug command
  if [ "$actual_command" = "debug" ]; then
    cmd_env_debug "$stack" "$env_prefix" "$env_file" "$@"
    return
  fi

  # Development commands only work with 'local' prefix
  case "$actual_command" in
    start|stop|reset|sync-env|sync-db|logs|test)
      [ "$env_prefix" = "local" ] || fail "Development commands (start/stop/reset/sync-env/sync-db/logs/test) only work with 'local' environment"
      ;;
    *)
      fail "Unknown command after $env_prefix: $actual_command"
      ;;
  esac

  case "$actual_command" in
    start)
      local_start "$stack" "$@"
      ;;
    stop)
      local_stop "$stack"
      ;;
    reset)
      local_reset "$stack"
      ;;
    sync-env)
      local source_env=""
      while [[ $# -gt 0 ]]; do
        case $1 in
          --from=*) source_env="${1#*=}"; shift ;;
          --from)   source_env="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      [ -z "$source_env" ] && fail "Usage: strut $stack local sync-env --from <env>"
      local_sync_env "$stack" "$source_env"
      ;;
    sync-db)
      local source_env=""
      local db_target="all"
      local anonymize_flag=""
      while [[ $# -gt 0 ]]; do
        case $1 in
          --from=*)    source_env="${1#*=}"; shift ;;
          --from)      source_env="$2"; shift 2 ;;
          --anonymize) anonymize_flag="--anonymize"; shift ;;
          postgres|neo4j|all) db_target="$1"; shift ;;
          *) shift ;;
        esac
      done
      [ -z "$source_env" ] && fail "Usage: strut $stack local sync-db --from <env> [postgres|neo4j|all] [--anonymize]"
      local_sync_db "$stack" "$source_env" "$db_target" $anonymize_flag
      ;;
    logs)
      local_logs "$stack" "$@"
      ;;
    test)
      local_test "$stack"
      ;;
    *)
      fail "Unknown local command: $actual_command

Available commands:
  start [--services <profile>]         Start stack locally
  stop                                  Stop local stack
  reset                                 Reset local environment (removes volumes)
  sync-env --from <env>                 Sync environment variables from production
  sync-db --from <env> [target] [--anonymize]
                                        Sync database from production (target: postgres|neo4j|all)
  logs [--follow]                       Tail logs from all services
  test                                  Run local smoke tests"
      ;;
  esac
}
