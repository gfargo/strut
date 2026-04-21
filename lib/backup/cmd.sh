#!/usr/bin/env bash
# ==================================================
# lib/backup/cmd.sh — Backup subsystem command dispatcher
# ==================================================
# Full dispatcher logic for `strut <stack> backup <subcommand>`.
# Called from lib/cmd_backup.sh thin-router.

set -euo pipefail

# backup_command <stack> <stack_dir> <env_file> <env_name> <services> <json_flag> [args...]
backup_command() {
  local stack="$1"
  local stack_dir="$2"
  local env_file="$3"
  local env_name="$4"
  local services="$5"
  local json_flag="$6"
  shift 6

  local positional=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      -*) break ;;
      *)  positional+=("$1"); shift ;;
    esac
  done
  local remaining_flags=("$@")

  local target="${positional[0]:-all}"
  local arg2="${positional[1]:-}"
  local arg3="${positional[2]:-}"
  local arg4="${positional[3]:-}"
  local arg5="${positional[4]:-}"

  local compose_cmd=""
  if [[ "$target" != "compare" && "$target" != "compare-labels" ]]; then
    validate_env_file "$env_file"
    export_volume_paths "$stack_dir"
    compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")
  fi

  # Fire pre_backup hook for actual backup-creation targets (not list/verify/etc).
  # Non-zero exit aborts. Skipped in DRY_RUN so dry-run stays side-effect-free.
  local is_backup_target=false
  case "$target" in
    postgres|neo4j|mysql|sqlite|gdrive-transcripts|all) is_backup_target=true ;;
  esac
  if [ "$is_backup_target" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    BACKUP_TARGET="$target" fire_hook pre_backup "$stack_dir" || \
      fail "pre_backup hook failed — aborting backup"
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
    postgres)
      if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}[DRY-RUN] Execution plan for backup:${NC}"
        run_cmd "Create backup directory" mkdir -p "$(_backup_dir "$stack")"
        run_cmd "Run pg_dump inside postgres container" echo "pg_dump → postgres-$(date +%Y%m%d-%H%M%S).sql"
        run_cmd "Create backup metadata" echo "metadata → backups/metadata/"
        echo ""
        echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
        return 0
      fi
      backup_postgres "$stack" "$compose_cmd"
      BACKUP_TARGET="postgres" fire_hook_or_warn post_backup "$stack_dir"
      notify_event backup.success stack="$stack" env="$env_name" type=postgres
      ;;
    neo4j)
      if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}[DRY-RUN] Execution plan for backup:${NC}"
        run_cmd "Stop Neo4j container" echo "docker stop neo4j (~10-30s downtime)"
        run_cmd "Create database dump" echo "neo4j-admin dump → neo4j-$(date +%Y%m%d-%H%M%S).dump"
        run_cmd "Restart Neo4j container" echo "docker start neo4j"
        run_cmd "Create backup metadata" echo "metadata → backups/metadata/"
        echo ""
        echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
        return 0
      fi
      backup_neo4j "$stack" "$compose_cmd"
      BACKUP_TARGET="neo4j" fire_hook_or_warn post_backup "$stack_dir"
      notify_event backup.success stack="$stack" env="$env_name" type=neo4j
      ;;
    mysql)
      if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}[DRY-RUN] Execution plan for backup:${NC}"
        run_cmd "Create backup directory" mkdir -p "$(_backup_dir "$stack")"
        run_cmd "Run mysqldump inside mysql container" echo "mysqldump → mysql-$(date +%Y%m%d-%H%M%S).sql"
        run_cmd "Create backup metadata" echo "metadata → backups/metadata/"
        echo ""
        echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
        return 0
      fi
      backup_mysql "$stack" "$compose_cmd"
      BACKUP_TARGET="mysql" fire_hook_or_warn post_backup "$stack_dir"
      notify_event backup.success stack="$stack" env="$env_name" type=mysql
      ;;
    sqlite)
      if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}[DRY-RUN] Execution plan for backup:${NC}"
        run_cmd "Create backup directory" mkdir -p "$(_backup_dir "$stack")"
        run_cmd "Copy SQLite database file" echo "cp → sqlite-$(date +%Y%m%d-%H%M%S).db"
        run_cmd "Create backup metadata" echo "metadata → backups/metadata/"
        echo ""
        echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
        return 0
      fi
      backup_sqlite "$stack" "$compose_cmd"
      BACKUP_TARGET="sqlite" fire_hook_or_warn post_backup "$stack_dir"
      notify_event backup.success stack="$stack" env="$env_name" type=sqlite
      ;;
    gdrive-transcripts)
      if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}[DRY-RUN] Execution plan for backup:${NC}"
        run_cmd "Create tarball of gdrive transcripts" echo "tar czf → gdrive-transcripts-$(date +%Y%m%d-%H%M%S).tar.gz"
        echo ""
        echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
        return 0
      fi
      backup_gdrive_transcripts "$stack" "$compose_cmd"
      BACKUP_TARGET="gdrive-transcripts" fire_hook_or_warn post_backup "$stack_dir"
      notify_event backup.success stack="$stack" env="$env_name" type=gdrive-transcripts
      ;;
    all)
      if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}[DRY-RUN] Execution plan for backup all:${NC}"
        local _backup_conf="$CLI_ROOT/stacks/$stack/backup.conf"
        if [ -f "$_backup_conf" ]; then
          set -a; source "$_backup_conf"; set +a
        fi
        [ "${BACKUP_POSTGRES:-true}" = "true" ] && run_cmd "Backup PostgreSQL" echo "pg_dump → postgres-*.sql"
        [ "${BACKUP_NEO4J:-false}" = "true" ] && run_cmd "Backup Neo4j (requires downtime)" echo "neo4j-admin dump → neo4j-*.dump"
        [ "${BACKUP_MYSQL:-false}" = "true" ] && run_cmd "Backup MySQL" echo "mysqldump → mysql-*.sql"
        [ "${BACKUP_SQLITE:-false}" = "true" ] && run_cmd "Backup SQLite" echo "cp → sqlite-*.db"
        run_cmd "Backup GDrive transcripts" echo "tar czf → gdrive-transcripts-*.tar.gz"
        echo ""
        echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
        return 0
      fi
      local _backup_conf="$CLI_ROOT/stacks/$stack/backup.conf"
      if [ -f "$_backup_conf" ]; then
        set -a; source "$_backup_conf"; set +a
      fi
      [ "${BACKUP_POSTGRES:-true}" = "true" ] && backup_postgres "$stack" "$compose_cmd"
      [ "${BACKUP_NEO4J:-false}" = "true" ] && backup_neo4j "$stack" "$compose_cmd"
      [ "${BACKUP_MYSQL:-false}" = "true" ] && backup_mysql "$stack" "$compose_cmd"
      [ "${BACKUP_SQLITE:-false}" = "true" ] && backup_sqlite "$stack" "$compose_cmd"
      backup_gdrive_transcripts "$stack" "$compose_cmd"
      BACKUP_TARGET="all" fire_hook_or_warn post_backup "$stack_dir"
      notify_event backup.success stack="$stack" env="$env_name" type=all
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
