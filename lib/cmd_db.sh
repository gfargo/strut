#!/usr/bin/env bash
# ==================================================
# cmd_db.sh — Database command handlers
# ==================================================
# Handles: db:pull, db:push, db:schema, restore, migrate (stack-level)
# Each function parses its own flags from positional args.

set -euo pipefail

_usage_restore() {
  echo ""
  echo "Usage: strut <stack> restore [--env <name>] <file> [--target-env <env>]"
  echo ""
  echo "Restore a database from a backup file. File type is auto-detected:"
  echo "  .sql       → PostgreSQL (or MySQL if filename starts with mysql-)"
  echo "  .dump      → Neo4j"
  echo "  .tar.gz    → Neo4j (legacy format)"
  echo "  .db        → SQLite"
  echo ""
  echo "Flags:"
  echo "  --target-env <env>   Restore to a different environment"
  echo "  --dry-run            Show execution plan without making changes"
  echo ""
  echo "Examples:"
  echo "  strut my-stack restore backups/postgres-20240101.sql --env prod"
  echo "  strut my-stack restore backups/neo4j-20240101.dump --env prod"
  echo ""
}

_usage_db_pull() {
  echo ""
  echo "Usage: strut <stack> db:pull [--env <name>] [target] [--download-only] [--file <name>]"
  echo ""
  echo "Pull latest backup from VPS and optionally restore to local dev environment."
  echo ""
  echo "Targets: postgres | neo4j | mysql | sqlite | all (default: all)"
  echo ""
  echo "Flags:"
  echo "  --download-only      Download backup without restoring"
  echo "  --file <name>        Pull a specific backup file by name"
  echo ""
  echo "Examples:"
  echo "  strut my-stack db:pull --env prod"
  echo "  strut my-stack db:pull --env prod postgres --download-only"
  echo "  strut my-stack db:pull --env prod --file postgres-20240101.sql"
  echo ""
}

_usage_db_push() {
  echo ""
  echo "Usage: strut <stack> db:push [--env <name>] [target] [--upload-only] [--file <name>]"
  echo ""
  echo "Upload local backup to VPS and optionally restore remotely."
  echo ""
  echo "Targets: postgres | neo4j | mysql | sqlite | all (default: all)"
  echo ""
  echo "Flags:"
  echo "  --upload-only        Upload backup without restoring on VPS"
  echo "  --file <name>        Push a specific backup file"
  echo "  --dry-run            Show execution plan without making changes"
  echo ""
  echo "Examples:"
  echo "  strut my-stack db:push --env prod postgres"
  echo "  strut my-stack db:push --env prod --upload-only"
  echo ""
}

# cmd_db_schema [action] (reads CMD_*)
cmd_db_schema() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"
  local schema_action="${1:-all}"

  validate_env_file "$env_file"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")

  case "$schema_action" in
    apply)  postgres_apply_init_sql "$stack" "$compose_cmd" "$stack_dir" ;;
    verify) postgres_verify_schema "$stack" "$compose_cmd" ;;
    all)
      postgres_apply_init_sql "$stack" "$compose_cmd" "$stack_dir"
      postgres_verify_schema "$stack" "$compose_cmd"
      ;;
    *) validate_subcommand "$schema_action" apply verify all || exit 1 ;;
  esac
}

# cmd_migrate_schema [target] [--status|--up|--down [N]] (reads CMD_*)
cmd_migrate_schema() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  # Parse migrate-specific args
  local migrate_target="neo4j"
  local migrate_action="--status"
  local migrate_steps="1"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --status) migrate_action="--status"; shift ;;
      --up)     migrate_action="--up"; shift ;;
      --down=*) migrate_action="--down"; migrate_steps="${1#*=}"; shift ;;
      --down)
        migrate_action="--down"
        if [[ $# -gt 1 && "$2" != -* ]]; then
          migrate_steps="$2"; shift 2
        else
          migrate_steps="1"; shift
        fi
        ;;
      neo4j|postgres) migrate_target="$1"; shift ;;
      *) shift ;;
    esac
  done

  validate_env_file "$env_file"

  local migrate_env_name
  migrate_env_name=$(extract_env_name "$env_file")
  local migrate_network="${stack}-${migrate_env_name}_default"
  local deploy_env_value="${env_name:-default}"

  case "$migrate_target" in
    neo4j)
      log "Running Neo4j schema migration ($migrate_action)..."
      local migrate_cmd
      if [ "$migrate_action" = "--down" ]; then
        migrate_cmd="python -m ch_ops.migrations.neo4j_migrator --down $migrate_steps"
      else
        migrate_cmd="python -m ch_ops.migrations.neo4j_migrator $migrate_action"
      fi
      docker run --rm --pull always \
        --network "$migrate_network" \
        -e NEO4J_URI="${NEO4J_URI}" \
        -e NEO4J_USER="${NEO4J_USER:-neo4j}" \
        -e NEO4J_PASSWORD="${NEO4J_PASSWORD}" \
        -e STACK_NAME="${stack}" \
        -e DEPLOY_ENV="${deploy_env_value}" \
        "${MIGRATION_IMAGE:?MIGRATION_IMAGE must be set in env file or services.conf}" \
        $migrate_cmd
      ;;
    postgres)
      local pg_action="${migrate_action:---up}"
      log "Running Postgres schema migration ($pg_action)..."
      local postgres_migrate_cmd
      if [ "$pg_action" = "--down" ]; then
        postgres_migrate_cmd="python -m ch_ops.migrations.postgres_migrator --down $migrate_steps"
      else
        postgres_migrate_cmd="python -m ch_ops.migrations.postgres_migrator $pg_action"
      fi
      docker run --rm --pull always \
        --network "$migrate_network" \
        -e DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}" \
        -e STACK_NAME="${stack}" \
        -e DEPLOY_ENV="${deploy_env_value}" \
        "${MIGRATION_IMAGE:?MIGRATION_IMAGE must be set in env file or services.conf}" \
        $postgres_migrate_cmd
      ;;
    *) validate_subcommand "$migrate_target" neo4j postgres || exit 1 ;;
  esac
}

# cmd_restore [file] [--target-env <env>] (reads CMD_*)
cmd_restore() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"

  # Parse restore-specific args
  local file=""
  local target_env=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --target-env=*) target_env="${1#*=}"; shift ;;
      --target-env)   target_env="$2"; shift 2 ;;
      -*) shift ;;
      *)  [ -z "$file" ] && file="$1"; shift ;;
    esac
  done

  [ -n "$file" ] || fail "Usage: strut $stack restore <file> [--target-env <env>]"
  validate_env_file "$env_file"

  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for restore:${NC}"
    run_cmd "Restore from backup file" echo "restore $file → $stack"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services")

  case "$file" in
    *.dump)   restore_neo4j    "$stack" "$compose_cmd" "$file" "$target_env" ;;
    *.tar.gz) restore_neo4j    "$stack" "$compose_cmd" "$file" "$target_env" ;;
    *.db)     restore_sqlite   "$stack" "$compose_cmd" "$file" "$target_env" ;;
    *.sql)
      case "$(basename "$file")" in
        mysql-*)   restore_mysql    "$stack" "$compose_cmd" "$file" "$target_env" ;;
        *)         restore_postgres "$stack" "$compose_cmd" "$file" "$target_env" ;;
      esac
      ;;
    *) fail "Unknown backup file type: $file (expected .dump/.tar.gz for Neo4j, .sql for Postgres/MySQL, or .db for SQLite)" ;;
  esac
}

# cmd_db_pull [target] [--download-only] [--file <name>] (reads CMD_*)
cmd_db_pull() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"

  local target="all"
  local download_only=false
  local specific_file=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --download-only) download_only=true; shift ;;
      --file=*)        specific_file="${1#*=}"; shift ;;
      --file)          specific_file="$2"; shift 2 ;;
      -*) shift ;;
      *)  target="$1"; shift ;;
    esac
  done

  validate_env_file "$env_file"
  validate_subcommand "$target" postgres neo4j mysql sqlite all || exit 1

  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for db:pull:${NC}"
    run_cmd "Connect to VPS via SSH" echo "ssh → find latest $target backup"
    run_cmd "Download backup from VPS" echo "rsync → local backups directory"
    if [ "$download_only" != "true" ]; then
      run_cmd "Restore $target database locally" echo "restore $target from downloaded backup"
    fi
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  db_pull "$stack" "$target" "$env_file" "$download_only" "$specific_file"
}

# cmd_db_push [target] [--upload-only] [--file <name>] (reads CMD_*)
cmd_db_push() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"

  local target="all"
  local upload_only=false
  local specific_file=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --upload-only) upload_only=true; shift ;;
      --file=*)      specific_file="${1#*=}"; shift ;;
      --file)        specific_file="$2"; shift 2 ;;
      -*) shift ;;
      *)  target="$1"; shift ;;
    esac
  done

  validate_env_file "$env_file"
  validate_subcommand "$target" postgres neo4j mysql sqlite all || exit 1

  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for db:push:${NC}"
    run_cmd "Upload and restore $target database" echo "db:push $target → $stack (file: ${specific_file:-latest})"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  db_push "$stack" "$target" "$env_file" "$upload_only" "$specific_file"
}
