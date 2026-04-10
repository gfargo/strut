#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-backup.sh — Phase 5: Pre-Cutover Backup
# ==================================================

# migrate_phase_backup <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 5: Pre-Cutover Backup
set -euo pipefail

migrate_phase_backup() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${YELLOW}Phase 5: Pre-Cutover Backup${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo -e "${YELLOW}⚠️  CRITICAL SAFETY STEP${NC}"
  echo ""
  echo "Before testing or cutting over to strut, we'll create backups"
  echo "of all databases and data stores from the EXISTING containers."
  echo ""
  echo "This provides a safety net for rollback if anything goes wrong."
  echo ""

  local stack_names="${MIGRATION_STACKS:-}"
  if [ -z "$stack_names" ]; then
    warn "No stacks to backup. Skipping backup phase."
    return 0
  fi

  # Get project mapping (stack_name:original_project)
  local project_mapping="${MIGRATION_PROJECT_MAPPING:-}"

  IFS=',' read -ra STACKS <<<"$stack_names"

  local backup_summary=()
  local backup_failed=false

  for stack in "${STACKS[@]}"; do
    stack=$(echo "$stack" | xargs)

    # Get original project name for this stack
    local original_project="$stack"
    if [ -n "$project_mapping" ]; then
      for mapping in ${project_mapping//,/ }; do
        local map_stack="${mapping%%:*}"
        local map_project="${mapping##*:}"
        if [ "$map_stack" = "$stack" ]; then
          original_project="$map_project"
          break
        fi
      done
    fi

    echo ""
    echo "Analyzing stack: $stack"
    if [ "$original_project" != "$stack" ]; then
      echo "(original project: $original_project)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Detect databases in this stack by checking running containers on VPS
    local audit_dir="${MIGRATION_AUDIT_DIR:-}"
    if [ -z "$audit_dir" ]; then
      audit_dir=$(ls -td "$CLI_ROOT/audits"/*-"$vps_host" 2>/dev/null | head -1)
    fi

    if [ -z "$audit_dir" ] || [ ! -f "$audit_dir/containers.jsonl" ]; then
      warn "No audit data found for $stack - skipping backup"
      continue
    fi

    # Find containers for this stack
    local has_postgres=false
    local has_neo4j=false
    local has_redis=false
    local has_mysql=false
    local has_sqlite=false
    local postgres_container=""
    local neo4j_container=""
    local mysql_container=""

    while IFS= read -r line; do
      local name image project
      name=$(echo "$line" | jq -r '.Names // ""' 2>/dev/null)
      image=$(echo "$line" | jq -r '.Image // ""' 2>/dev/null)
      labels=$(echo "$line" | jq -r '.Labels // ""' 2>/dev/null)

      # Extract project name
      project=""
      if echo "$labels" | grep -q "com.docker.compose.project="; then
        project=$(echo "$labels" | tr ',' '\n' | grep "com.docker.compose.project=" | head -1 | cut -d'=' -f2)
      fi
      [ -z "$project" ] && project=$(echo "$name" | cut -d'-' -f1 | cut -d'_' -f1)

      # Skip if not this stack (check both stack name and original project name)
      [ "$project" != "$stack" ] && [ "$project" != "$original_project" ] && continue

      # Detect database types
      if echo "$image" | grep -qi "postgres"; then
        has_postgres=true
        postgres_container="$name"
      elif echo "$image" | grep -qi "neo4j"; then
        has_neo4j=true
        neo4j_container="$name"
      elif echo "$image" | grep -qi "mysql\|mariadb"; then
        has_mysql=true
        mysql_container="$name"
      elif echo "$image" | grep -qi "redis"; then
        has_redis=true
      fi
    done <"$audit_dir/containers.jsonl"

    # Also check backup.conf for host-level databases (e.g. SQLite)
    local backup_conf="$CLI_ROOT/stacks/$stack/backup.conf"
    if [ -f "$backup_conf" ]; then
      local conf_sqlite conf_mysql conf_postgres conf_neo4j
      conf_sqlite=$(grep '^BACKUP_SQLITE=' "$backup_conf" 2>/dev/null | cut -d= -f2 || true)
      conf_mysql=$(grep '^BACKUP_MYSQL=' "$backup_conf" 2>/dev/null | cut -d= -f2 || true)
      conf_postgres=$(grep '^BACKUP_POSTGRES=' "$backup_conf" 2>/dev/null | cut -d= -f2 || true)
      conf_neo4j=$(grep '^BACKUP_NEO4J=' "$backup_conf" 2>/dev/null | cut -d= -f2 || true)

      [ "$conf_sqlite" = "true" ] && has_sqlite=true
      [ "$conf_mysql" = "true" ] && [ "$has_mysql" = false ] && has_mysql=true
      [ "$conf_postgres" = "true" ] && [ "$has_postgres" = false ] && has_postgres=true
      [ "$conf_neo4j" = "true" ] && [ "$has_neo4j" = false ] && has_neo4j=true
    fi

    # Report findings
    if [ "$has_postgres" = false ] && [ "$has_neo4j" = false ] && [ "$has_redis" = false ] && [ "$has_mysql" = false ] && [ "$has_sqlite" = false ]; then
      log "No databases detected in $stack - skipping backup"
      backup_summary+=("$stack: No databases (skipped)")
      continue
    fi

    echo ""
    echo "Databases detected:"
    [ "$has_postgres" = true ] && echo "  ✓ PostgreSQL ($postgres_container)"
    [ "$has_neo4j" = true ] && echo "  ✓ Neo4j ($neo4j_container)"
    [ "$has_mysql" = true ] && echo "  ✓ MySQL ($mysql_container)"
    [ "$has_sqlite" = true ] && echo "  ✓ SQLite (host filesystem)"
    [ "$has_redis" = true ] && echo "  ✓ Redis (in-memory, no backup needed)"
    echo ""

    if ! confirm "Create pre-migration backups for $stack?"; then
      warn "Skipping backup for $stack"
      backup_summary+=("$stack: Skipped by user")
      continue
    fi

    # Create backup directory (use original project name for consistency)
    local backup_dir="$CLI_ROOT/backups/pre-migration-$original_project-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    log "Backup directory: $backup_dir"

    # Sudo prefix for docker commands (VPS_SUDO=true for hosts where
    # the deploy user is not in the docker group)
    local _sudo
    _sudo="$(vps_sudo_prefix)"

    local stack_backup_success=true

    # Backup PostgreSQL
    if [ "$has_postgres" = true ]; then
      log "Backing up PostgreSQL from $postgres_container..."

      # Detect database name (try common names: default, postgres, or list all)
      local db_name
      db_name=$(ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
        "${_sudo}docker exec $postgres_container psql -U postgres -lqt | cut -d '|' -f 1 | grep -v -E '(template0|template1|postgres)' | grep -v '^$' | head -1 | xargs" 2>/dev/null)

      # Default to 'postgres' if detection fails
      db_name="${db_name:-postgres}"
      log "Detected database: $db_name"

      local pg_backup="$backup_dir/postgres-pre-migration.sql"
      if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
        "${_sudo}docker exec $postgres_container pg_dump -U postgres -d $db_name" >"$pg_backup" 2>/dev/null; then
        local size
        size=$(du -h "$pg_backup" | cut -f1)
        ok "PostgreSQL backup saved: $pg_backup ($size)"
      else
        error "PostgreSQL backup failed for $stack"
        stack_backup_success=false
        backup_failed=true
      fi
    fi

    # Backup Neo4j
    if [ "$has_neo4j" = true ]; then
      log "Backing up Neo4j from $neo4j_container..."

      local neo4j_backup="$backup_dir/neo4j-pre-migration.dump"

      # Try neo4j-admin dump (may fail if database is running)
      if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
        "${_sudo}docker exec $neo4j_container neo4j-admin database dump neo4j --to-path=/tmp/backup.dump 2>/dev/null && \
         ${_sudo}docker cp $neo4j_container:/tmp/backup.dump - 2>/dev/null" >"$neo4j_backup" 2>/dev/null; then
        local size
        size=$(du -h "$neo4j_backup" | cut -f1)
        ok "Neo4j backup saved: $neo4j_backup ($size)"
      else
        warn "Neo4j backup failed (could not locate Neo4j container or create dump)"
        rm -f "$neo4j_backup"
      fi
    fi

    # Backup MySQL
    if [ "$has_mysql" = true ] && [ -n "$mysql_container" ]; then
      log "Backing up MySQL from $mysql_container..."

      local mysql_backup="$backup_dir/mysql-pre-migration.sql"
      if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
        "${_sudo}docker exec $mysql_container mysqldump -u root --all-databases" >"$mysql_backup" 2>/dev/null; then
        local size
        size=$(du -h "$mysql_backup" | cut -f1)
        ok "MySQL backup saved: $mysql_backup ($size)"
      else
        error "MySQL backup failed for $stack"
        stack_backup_success=false
        backup_failed=true
      fi
    fi

    # Backup SQLite (host filesystem — uses backup.conf path)
    if [ "$has_sqlite" = true ]; then
      local sqlite_path=""
      if [ -f "$backup_conf" ]; then
        sqlite_path=$(grep '^BACKUP_SQLITE_PATH=' "$backup_conf" | cut -d= -f2- || true)
      fi

      if [ -n "$sqlite_path" ]; then
        log "Backing up SQLite from $sqlite_path..."

        local sqlite_backup="$backup_dir/sqlite-pre-migration.db"
        local remote_tmp="/tmp/sqlite-pre-migration-$$.db"

        # Use sqlite3 .backup if available, otherwise plain copy
        local sqlite_copy_ok=false
        if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
          "command -v sqlite3 >/dev/null 2>&1" 2>/dev/null; then
          if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
            "${_sudo}sqlite3 '$sqlite_path' '.backup $remote_tmp'" 2>/dev/null; then
            sqlite_copy_ok=true
          fi
        else
          if ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
            "${_sudo}cp '$sqlite_path' '$remote_tmp'" 2>/dev/null; then
            sqlite_copy_ok=true
          fi
        fi

        if [ "$sqlite_copy_ok" = true ]; then
          # Download the backup
          local ssh_opts
          ssh_opts=$(build_ssh_opts -p "$ssh_port" -k "$ssh_key")

          if rsync -avz -e "ssh $ssh_opts" \
            "$vps_user@$vps_host:$remote_tmp" "$sqlite_backup" 2>/dev/null; then
            local size
            size=$(du -h "$sqlite_backup" | cut -f1)
            ok "SQLite backup saved: $sqlite_backup ($size)"
            # Cleanup remote temp
            ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
              "${_sudo}rm -f '$remote_tmp'" 2>/dev/null || true
          else
            error "SQLite download failed for $stack"
            stack_backup_success=false
            backup_failed=true
          fi
        else
          error "SQLite backup failed for $stack (could not copy on VPS)"
          stack_backup_success=false
          backup_failed=true
        fi
      else
        warn "SQLite enabled in backup.conf but BACKUP_SQLITE_PATH not set — skipping"
      fi
    fi

    # Summary for this stack
    if [ "$stack_backup_success" = true ]; then
      backup_summary+=("$stack: ✓ Backed up to $backup_dir")

      # Create rollback instructions
      cat >"$backup_dir/ROLLBACK.md" <<EOF
# Rollback Instructions for $stack

## Pre-Migration Backup
Created: $(date)
VPS: $vps_host
Stack: $stack

## Files in this backup:
$(ls -lh "$backup_dir" | tail -n +2)

## To rollback if migration fails:

### 1. Stop strut stack
\`\`\`bash
strut $stack status --env $stack-prod
docker compose --project-name $stack-prod down
\`\`\`

### 2. Restart old containers
\`\`\`bash
EOF

      # Add container restart commands only for detected databases
      if [ "$has_postgres" = true ] || [ "$has_neo4j" = true ]; then
        echo "ssh $vps_user@$vps_host \"docker start${has_postgres:+ $postgres_container}${has_neo4j:+ $neo4j_container}\"" >>"$backup_dir/ROLLBACK.md"
      fi

      cat >>"$backup_dir/ROLLBACK.md" <<EOF
\`\`\`

### 3. If data corruption occurred, restore from these backups:

EOF

      # Add PostgreSQL restore instructions only if backed up
      if [ "$has_postgres" = true ] && [ -f "$backup_dir/postgres-pre-migration.sql" ]; then
        cat >>"$backup_dir/ROLLBACK.md" <<EOF
#### PostgreSQL:
\`\`\`bash
cat $backup_dir/postgres-pre-migration.sql | ssh $vps_user@$vps_host "docker exec -i $postgres_container psql -U postgres"
\`\`\`

EOF
      fi

      # Add Neo4j restore instructions only if backed up
      if [ "$has_neo4j" = true ] && [ -f "$backup_dir/neo4j-pre-migration.dump" ]; then
        cat >>"$backup_dir/ROLLBACK.md" <<EOF
#### Neo4j:
\`\`\`bash
# Copy backup to VPS
scp $backup_dir/neo4j-pre-migration.dump $vps_user@$vps_host:/tmp/restore.dump

# Stop Neo4j, restore, restart
ssh $vps_user@$vps_host "docker stop $neo4j_container && \\
  docker cp /tmp/restore.dump $neo4j_container:/var/lib/neo4j/import/restore.dump && \\
  docker start $neo4j_container && \\
  docker exec $neo4j_container neo4j-admin database load neo4j --from-path=/var/lib/neo4j/import/restore.dump --overwrite-destination"
\`\`\`

EOF
      fi

      cat >>"$backup_dir/ROLLBACK.md" <<EOF
## Backup retention
Keep these backups for at least 30 days after successful migration.
EOF
      ok "Rollback instructions: $backup_dir/ROLLBACK.md"
    else
      backup_summary+=("$stack: ✗ Backup failed")
    fi
  done

  # Final summary
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Backup Summary:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for summary in "${backup_summary[@]}"; do
    echo "  $summary"
  done
  echo ""

  if [ "$backup_failed" = true ]; then
    error "Some backups failed!"
    warn "It's strongly recommended to resolve backup issues before proceeding."
    echo ""
    if ! confirm "Continue anyway? (NOT RECOMMENDED)"; then
      log "Migration paused. Fix backup issues and run wizard again."
      exit 1
    fi
  else
    ok "All backups complete"
  fi

  echo ""
  if ! confirm "Continue to testing?"; then
    log "Migration paused. Backups are saved. Run wizard again to continue."
    exit 0
  fi
}
