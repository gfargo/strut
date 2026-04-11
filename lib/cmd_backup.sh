#!/usr/bin/env bash
# ==================================================
# cmd_backup.sh — Backup command handler
# ==================================================
# Dispatches all backup subcommands. Parses its own positional args.
#
# Usage (from strut entrypoint):
#   cmd_backup <stack> <stack_dir> <env_file> <env_name> <services> <json_flag> [positional...]

set -euo pipefail

_usage_backup() {
  echo ""
  echo "Usage: strut <stack> backup [--env <name>] <subcommand> [options]"
  echo ""
  echo "Backup management: create, verify, schedule, and monitor backups."
  echo ""
  echo "Subcommands:"
  echo "  postgres|neo4j|mysql|sqlite|all   Create backup for service(s)"
  echo "  verify <file> [--full]            Verify backup integrity"
  echo "  verify-all                        Verify all backups"
  echo "  list [service]                    List available backups"
  echo "  health                            Check backup health scores"
  echo "  schedule on|off|status|install    Manage backup schedules"
  echo "  retention check|enforce           Manage retention policy"
  echo "  compare <env1> <env2> [service]   Compare backups across environments"
  echo "  compare-labels <env1> <env2>      Compare backup labels"
  echo ""
  echo "Examples:"
  echo "  strut my-stack backup postgres --env prod"
  echo "  strut my-stack backup all --env prod"
  echo "  strut my-stack backup verify backups/postgres-20240101.sql"
  echo "  strut my-stack backup list postgres"
  echo "  strut my-stack backup health"
  echo "  strut my-stack backup schedule status"
  echo "  strut my-stack backup retention enforce"
  echo ""
}

cmd_backup() {
  local stack="$1"
  local stack_dir="$2"
  local env_file="$3"
  local env_name="$4"
  local services="$5"
  local json_flag="$6"
  shift 6

  # Parse backup-specific positional args
  local positional=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      -*) break ;;  # leave flags for subcommands
      *)  positional+=("$1"); shift ;;
    esac
  done
  local remaining_flags=("$@")

  local target="${positional[0]:-all}"
  local arg2="${positional[1]:-}"
  local arg3="${positional[2]:-}"
  local arg4="${positional[3]:-}"
  local arg5="${positional[4]:-}"

  # Compare commands don't need ENV_FILE since they work across environments
  local compose_cmd=""
  if [[ "$target" != "compare" && "$target" != "compare-labels" ]]; then
    validate_env_file "$env_file"
    export_volume_paths "$stack_dir"
    compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")
  fi

  case "$target" in
    verify)
      [ -z "$arg2" ] && fail "Usage: strut $stack backup verify <backup-file> [--full]"
      backup_verify_cmd "$stack" "$arg2" "$compose_cmd" "${remaining_flags[0]:-}"
      ;;
    verify-all)
      backup_verify_all_cmd "$stack" "$compose_cmd"
      ;;
    list)
      backup_list_cmd "$stack" "$json_flag"
      ;;
    health)
      backup_health_cmd "$stack" "${arg2:-all}" "$json_flag"
      ;;
    schedule)
      case "$arg2" in
        set)
          [ -z "$arg3" ] || [ -z "$arg4" ] && \
            fail "Usage: strut $stack backup schedule set <service> <cron-expression>"
          backup_schedule_set_cmd "$stack" "$arg3" "$arg4" "$env_name"
          ;;
        list)
          backup_schedule_list_cmd "$stack"
          ;;
        install-defaults)
          backup_schedule_install_defaults_cmd "$stack" "$env_name"
          ;;
        *)
          fail "Unknown schedule subcommand: $arg2 (set|list|install-defaults)"
          ;;
      esac
      ;;
    retention)
      case "$arg2" in
        enforce)
          if [ "$DRY_RUN" = "true" ]; then
            echo ""
            echo -e "${YELLOW}[DRY-RUN] Execution plan for retention enforce:${NC}"
            run_cmd "Enforce retention policy for ${arg3:-all} services" echo "retention enforce ${arg3:-all} → $stack"
            echo ""
            echo -e "${YELLOW}[DRY-RUN] No backups deleted.${NC}"
            return 0
          fi
          backup_retention_enforce_cmd "$stack" "${arg3:-all}"
          ;;
        install-cron)
          backup_retention_install_cron_cmd "$stack"
          ;;
        *)
          fail "Unknown retention subcommand: $arg2 (enforce|install-cron)"
          ;;
      esac
      ;;
    storage)
      backup_storage_stats_cmd "$stack"
      ;;
    check-missed)
      backup_check_missed_cmd "$stack"
      ;;
    compare)
      [ -z "$arg2" ] || [ -z "$arg3" ] && \
        fail "Usage: strut $stack backup compare <env1> <env2> [--service neo4j|postgres|all]"
      local compare_service="all"
      compare_neo4j_databases "$stack" "$arg2" "$arg3"
      echo ""
      compare_postgres_databases "$stack" "$arg2" "$arg3"
      ;;
    compare-labels)
      [ -z "$arg2" ] || [ -z "$arg3" ] && \
        fail "Usage: strut $stack backup compare-labels <env1> <env2>"
      compare_neo4j_labels "$stack" "$arg2" "$arg3"
      ;;
    postgres)          backup_postgres "$stack" "$compose_cmd" ;;
    neo4j)             backup_neo4j "$stack" "$compose_cmd" ;;
    mysql)             backup_mysql "$stack" "$compose_cmd" ;;
    sqlite)            backup_sqlite "$stack" "$compose_cmd" ;;
    gdrive-transcripts) backup_gdrive_transcripts "$stack" "$compose_cmd" ;;
    all)
      local _backup_conf="$CLI_ROOT/stacks/$stack/backup.conf"
      if [ -f "$_backup_conf" ]; then
        set -a; source "$_backup_conf"; set +a
      fi
      [ "${BACKUP_POSTGRES:-true}" = "true" ] && backup_postgres "$stack" "$compose_cmd"
      [ "${BACKUP_NEO4J:-false}" = "true" ] && backup_neo4j "$stack" "$compose_cmd"
      [ "${BACKUP_MYSQL:-false}" = "true" ] && backup_mysql "$stack" "$compose_cmd"
      [ "${BACKUP_SQLITE:-false}" = "true" ] && backup_sqlite "$stack" "$compose_cmd"
      backup_gdrive_transcripts "$stack" "$compose_cmd"
      ;;
    *)
      fail "Unknown backup command: $target

Available commands:
  postgres                              Create PostgreSQL backup
  neo4j                                 Create Neo4j backup
  mysql                                 Create MySQL backup
  sqlite                                Create SQLite backup
  gdrive-transcripts                    Create GDrive transcripts backup
  all                                   Create all backups (per backup.conf)
  verify <file> [--full]                Verify a specific backup
  verify-all                            Verify all backups
  list [--json]                         List all backups with metadata
  health [service] [--json]             Show backup health status
  schedule set <service> <cron>         Set backup schedule
  schedule list                         List backup schedules
  schedule install-defaults             Install default schedules
  retention enforce [service]           Enforce retention policy
  retention install-cron                Install retention cron job
  storage                               Show storage statistics
  check-missed                          Check for missed backups
  compare <env1> <env2> [--service X]   Compare databases between environments
  compare-labels <env1> <env2>          Compare Neo4j label distribution"
      ;;
  esac
}
