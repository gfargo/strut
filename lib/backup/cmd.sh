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
  if [[ "$target" != "compare" && "$target" != "compare-labels" && "$target" != "offsite" ]]; then
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

  # Load backup.conf up front so every per-engine backup/restore function sees
  # BACKUP_POSTGRES_SERVICE / BACKUP_NEO4J_SERVICE / BACKUP_MYSQL_SERVICE /
  # BACKUP_LOCAL_DIR regardless of which target is invoked (previously only
  # the "all" and "offsite" targets loaded this config at all).
  if [ "$is_backup_target" = "true" ]; then
    load_backup_conf "$stack" "$stack_dir" || fail "Failed to load backup.conf for $stack"
  fi

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
    offsite)
      # Load backup.conf so offsite_* helpers see BACKUP_OFFSITE* vars.
      load_backup_conf "$stack" "$stack_dir" || return 1

      case "$arg2" in
        ""|status)  offsite_status ;;
        sync)       offsite_sync_all "$stack" ;;
        list)       offsite_list "$stack" ;;
        restore)
          [ -z "$arg3" ] && fail "Usage: strut $stack backup offsite restore <filename>"
          offsite_restore "$stack" "$arg3"
          ;;
        *)
          fail "Unknown offsite subcommand: $arg2 (status|sync|list|restore)"
          ;;
      esac
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
        offsite_enabled 2>/dev/null && \
          run_cmd "Offsite sync (${BACKUP_OFFSITE})" echo "$(_offsite_remote_url "$stack" "postgres-*.sql")"
        echo ""
        echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
        return 0
      fi
      if ! backup_postgres "$stack" "$compose_cmd"; then
        alert_backup_failure "$stack" "postgres" "pg_dump failed — see logs above"
        return 1
      fi
      offsite_sync_latest "$stack" "postgres-*.sql"
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
      if ! backup_neo4j "$stack" "$compose_cmd"; then
        alert_backup_failure "$stack" "neo4j" "neo4j-admin dump failed — see logs above"
        return 1
      fi
      offsite_sync_latest "$stack" "neo4j-*.dump"
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
      if ! backup_mysql "$stack" "$compose_cmd"; then
        alert_backup_failure "$stack" "mysql" "mysqldump failed — see logs above"
        return 1
      fi
      offsite_sync_latest "$stack" "mysql-*.sql"
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
      if ! backup_sqlite "$stack" "$compose_cmd"; then
        alert_backup_failure "$stack" "sqlite" "sqlite backup failed — see logs above"
        return 1
      fi
      offsite_sync_latest "$stack" "sqlite-*.db"
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
        local engine
        for engine in "${BACKUP_ENGINES[@]}"; do
          backup_engine_enabled "$engine" || continue
          local label dump_desc
          case "$engine" in
            postgres) label="Backup PostgreSQL"; dump_desc="pg_dump" ;;
            neo4j)    label="Backup Neo4j (requires downtime)"; dump_desc="neo4j-admin dump" ;;
            mysql)    label="Backup MySQL"; dump_desc="mysqldump" ;;
            sqlite)   label="Backup SQLite"; dump_desc="cp" ;;
          esac
          run_cmd "$label" echo "$dump_desc → $(backup_engine_glob "$engine")"
        done
        run_cmd "Backup GDrive transcripts" echo "tar czf → gdrive-transcripts-*.tar.gz"
        echo ""
        echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
        return 0
      fi
      local engine
      for engine in "${BACKUP_ENGINES[@]}"; do
        if backup_engine_enabled "$engine"; then
          local dump_fn
          dump_fn=$(backup_dump_fn "$engine")
          "$dump_fn" "$stack" "$compose_cmd"
        fi
      done
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
  compare-labels <env1> <env2>          Compare Neo4j label distribution
  offsite status|sync|list|restore ...  Offsite backup sync (S3/R2/B2)"
      ;;
  esac
}
