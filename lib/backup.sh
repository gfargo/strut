#!/usr/bin/env bash
# ==================================================
# lib/backup.sh — Backup and restore stubs
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Future: add S3/offsite backup in Phase 4.
# For now: local dumps to stacks/<stack>/backups/

# Source backup submodules
set -euo pipefail

BACKUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup"
[ -f "$BACKUP_LIB_DIR/verify.sh" ] && source "$BACKUP_LIB_DIR/verify.sh"
[ -f "$BACKUP_LIB_DIR/schedule.sh" ] && source "$BACKUP_LIB_DIR/schedule.sh"
[ -f "$BACKUP_LIB_DIR/retention.sh" ] && source "$BACKUP_LIB_DIR/retention.sh"
[ -f "$BACKUP_LIB_DIR/health.sh" ] && source "$BACKUP_LIB_DIR/health.sh"
[ -f "$BACKUP_LIB_DIR/compare.sh" ] && source "$BACKUP_LIB_DIR/compare.sh"
[ -f "$BACKUP_LIB_DIR/mysql.sh" ] && source "$BACKUP_LIB_DIR/mysql.sh"
[ -f "$BACKUP_LIB_DIR/sqlite.sh" ] && source "$BACKUP_LIB_DIR/sqlite.sh"
[ -f "$BACKUP_LIB_DIR/offsite.sh" ] && source "$BACKUP_LIB_DIR/offsite.sh"
[ -f "$BACKUP_LIB_DIR/cmd.sh" ] && source "$BACKUP_LIB_DIR/cmd.sh"

# _backup_dir <stack>
# Returns the backup directory for a stack.
# Priority: BACKUP_LOCAL_DIR (from backup.conf) > default stacks/<stack>/backups
_backup_dir() {
  local stack="$1"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  # If BACKUP_LOCAL_DIR is already set (e.g. via export_volume_paths + backup.conf),
  # use it directly.
  if [ -n "${BACKUP_LOCAL_DIR:-}" ]; then
    echo "$BACKUP_LOCAL_DIR"
    return
  fi

  # Try sourcing volume.conf then backup.conf for this stack
  local stack_dir="$cli_root/stacks/$stack"
  if [ -f "$stack_dir/volume.conf" ]; then
    # shellcheck disable=SC1090
    source <(preprocess_config "$stack_dir/volume.conf")
  fi
  if [ -f "$stack_dir/backup.conf" ]; then
    # shellcheck disable=SC1090
    source <(preprocess_config "$stack_dir/backup.conf")
  fi

  # BACKUP_LOCAL_DIR in backup.conf references ${BACKUP_PATH} from volume.conf
  if [ -n "${BACKUP_LOCAL_DIR:-}" ]; then
    echo "$BACKUP_LOCAL_DIR"
    return
  fi

  # Fallback: default path on root disk
  echo "$cli_root/stacks/$stack/backups"
}

# _remote_backup_dir <stack> <ssh_opts> <vps_user> <vps_host> <vps_deploy_dir>
# Resolves the backup directory on a remote VPS by sourcing its volume.conf/backup.conf.
# Falls back to the default stacks/<stack>/backups path.
_remote_backup_dir() {
  local stack="$1"
  local ssh_opts="$2"
  local vps_user="$3"
  local vps_host="$4"
  local vps_deploy_dir="$5"

  local _resolved
  _resolved=$(ssh $ssh_opts "$vps_user@$vps_host" \
    "if [ -f '$vps_deploy_dir/stacks/$stack/volume.conf' ]; then . '$vps_deploy_dir/stacks/$stack/volume.conf'; fi; \
     if [ -f '$vps_deploy_dir/stacks/$stack/backup.conf' ]; then . '$vps_deploy_dir/stacks/$stack/backup.conf'; fi; \
     echo \"\${BACKUP_LOCAL_DIR:-}\"" 2>/dev/null || echo "")

  if [ -n "$_resolved" ]; then
    echo "$_resolved"
  else
    echo "$vps_deploy_dir/stacks/$stack/backups"
  fi
}

# _docker_wait_stop <container_name> [max_wait]
# Waits for a container to reach "exited" state. Returns 1 on timeout.
_docker_wait_stop() {
  local container_name="$1"
  local max_wait="${2:-30}"
  local waited=0
  while [ $waited -lt $max_wait ]; do
    local status
    status=$(${_sudo:-}docker inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null)
    if [ "$status" = "exited" ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# _docker_wait_healthy <compose_cmd> <service> [max_wait]
# Waits for a compose service to report healthy. Returns 1 on timeout.
_docker_wait_healthy() {
  local compose_cmd="$1"
  local service="$2"
  local max_wait="${3:-60}"
  local waited=0
  while [ $waited -lt $max_wait ]; do
    if ${_sudo:-}$compose_cmd ps "$service" --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# backup_neo4j <stack> <compose_cmd>
# Creates a Neo4j database dump inside the Neo4j container and copies it locally.
# Note: Neo4j Community Edition requires stopping the database to create a dump.
backup_neo4j() {
  local stack="$1"
  local compose_cmd="$2"
  local backup_dir
  backup_dir=$(_backup_dir "$stack")
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local out="$backup_dir/neo4j-$timestamp.dump"

  mkdir -p "$backup_dir"
  log "Backing up Neo4j → $out"

  warn "Neo4j Community Edition requires stopping the database to create a backup (~10-30s downtime)"

  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  local container_name
  container_name=$(${_sudo}docker ps --filter "name=neo4j" --format "{{.Names}}" | grep "$stack" | head -1)
  [ -n "$container_name" ] || { error "Neo4j container not found for stack: $stack"; return 1; }

  log "Using container: $container_name"

  # Stop Neo4j
  log "Stopping Neo4j..."
  ${_sudo}docker stop "$container_name" >/dev/null 2>&1 || { error "Failed to stop Neo4j"; return 1; }

  log "Waiting for Neo4j to stop..."
  if ! _docker_wait_stop "$container_name" 30; then
    error "Neo4j did not stop within 30s"
    return 1
  fi
  ok "Neo4j stopped"

  # Create dump
  log "Creating database dump..."

  local data_source
  data_source=$(${_sudo}docker inspect "$container_name" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
  if [ -z "$data_source" ]; then
    error "Could not find Neo4j data mount"
    ${_sudo}docker start "$container_name" >/dev/null 2>&1
    return 1
  fi

  local import_source
  import_source=$(${_sudo}docker inspect "$container_name" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/neo4j/import"}}{{.Source}}{{end}}{{end}}')

  if ! ${_sudo}docker run --rm \
    -v "$data_source:/data" \
    -v "$import_source:/var/lib/neo4j/import" \
    --entrypoint neo4j-admin \
    neo4j:5.15-community \
    database dump neo4j --to-path=/var/lib/neo4j/import --overwrite-destination=true 2>&1 | tee /dev/stderr | grep -q "Dump completed successfully"; then
    error "Failed to create Neo4j dump"
    ${_sudo}docker start "$container_name" >/dev/null 2>&1
    return 1
  fi

  # Restart Neo4j
  log "Restarting Neo4j..."
  ${_sudo}docker start "$container_name" >/dev/null 2>&1 || { error "Failed to restart Neo4j"; return 1; }

  # Copy dump to backup directory
  log "Copying dump to backup directory..."
  ${_sudo}docker cp "$container_name:/var/lib/neo4j/import/neo4j.dump" "$out" 2>/dev/null || { error "Failed to copy Neo4j dump"; return 1; }
  ${_sudo}docker exec "$container_name" rm -f /var/lib/neo4j/import/neo4j.dump 2>/dev/null || true

  # Wait for healthy
  log "Waiting for Neo4j to be healthy..."
  if _docker_wait_healthy "$compose_cmd" "neo4j" 60; then
    ok "Neo4j is healthy again"
  else
    warn "Neo4j did not become healthy within 60s, but backup was created"
  fi

  ok "Neo4j backup saved: $out"
  create_backup_metadata "$stack" "$out" "neo4j" ""
}

# backup_postgres <stack> <compose_cmd>
# Creates a pg_dump and saves it locally.
# Supports BACKUP_POSTGRES_SERVICE in backup.conf for stacks where the
# Postgres compose service is not named "postgres" (e.g. twenty uses "db").
backup_postgres() {
  local stack="$1"
  local compose_cmd="$2"
  local backup_dir
  backup_dir=$(_backup_dir "$stack")
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local out="$backup_dir/postgres-$timestamp.sql"

  # Resolve compose service name (default: postgres)
  local pg_service="${BACKUP_POSTGRES_SERVICE:-postgres}"

  mkdir -p "$backup_dir"
  log "Backing up PostgreSQL (service: $pg_service) → $out"

  # Sudo prefix for VPS hosts where deploy user needs sudo for Docker
  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  ${_sudo}$compose_cmd exec -T "$pg_service" \
    pg_dump -U "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-app_db}" > "$out" \
  && ok "PostgreSQL backup saved: $out" \
  && create_backup_metadata "$stack" "$out" "postgres" "" \
  || { error "PostgreSQL backup failed"; return 1; }
}

# backup_gdrive_transcripts <stack> <compose_cmd>
# Creates a tarball of gdrive transcripts directory.
backup_gdrive_transcripts() {
  local stack="$1"
  local compose_cmd="$2"
  local backup_dir
  backup_dir=$(_backup_dir "$stack")
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local out="$backup_dir/gdrive-transcripts-$timestamp.tar.gz"

  mkdir -p "$backup_dir"
  log "Backing up GDrive transcripts → $out"

  # Check if ch-ingest-gdrive service exists and is running
  if ! $compose_cmd ps --services 2>/dev/null | grep -q "ch-ingest-gdrive"; then
    warn "ch-ingest-gdrive service not found in stack (may not be deployed with gdrive profile)"
    return 0
  fi

  # Create tarball from container's gdrive_transcripts directory
  $compose_cmd exec -T ch-ingest-gdrive tar czf - -C /app gdrive_transcripts 2>/dev/null > "$out" \
  && ok "GDrive transcripts backup saved: $out" \
  || { warn "GDrive transcripts backup failed (directory may be empty or service not running)"; return 0; }
}

# restore_neo4j <stack> <compose_cmd> <dump_file> [target_env]
# Restores Neo4j from a dump file or tar.gz archive
# If target_env is provided, uses that env's compose setup (for cross-env restores)
restore_neo4j() {
  local stack="$1"
  local compose_cmd="$2"
  local dump_file="$3"
  local target_env="${4:-}"  # Optional: target environment override

  [ -f "$dump_file" ] || fail "Dump file not found: $dump_file"

  # Check if this is a tar.gz archive (old format) or a .dump file (new format)
  if [[ "$dump_file" == *.tar.gz ]]; then
    restore_neo4j_from_targz "$stack" "$compose_cmd" "$dump_file" "$target_env"
    return $?
  fi

  # If target_env is provided, rebuild compose_cmd for that environment
  if [ -n "$target_env" ]; then
    local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local target_env_file="$cli_root/.${target_env}.env"
    [ -f "$target_env_file" ] || fail "Target env file not found: $target_env_file"

    log "Restoring to target environment: $target_env"
    compose_cmd=$(resolve_compose_cmd "$stack" "$target_env_file" "")
  fi

  warn "This will STOP Neo4j, restore from dump, then restart it."
  confirm "Continue?" || { ok "Restore cancelled"; return 0; }

  # Get container name for direct docker operations
  # Try to find the neo4j container by searching docker ps
  local container_name
  container_name=$(docker ps -a --format "{{.Names}}" | grep -E "^${stack}.*neo4j" | head -1)

  if [ -z "$container_name" ]; then
    # Fallback: derive from compose project name
    local project_name
    if [[ "$compose_cmd" =~ --project-name[[:space:]]+([^[:space:]]+) ]]; then
      project_name="${BASH_REMATCH[1]}"
    else
      project_name="$stack"
    fi
    container_name="${project_name}-neo4j-1"
  fi

  if ! docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    error "Neo4j container not found: $container_name"
    return 1
  fi

  log "Using container: $container_name"
  log "Stopping Neo4j for restore..."
  docker stop "$container_name" >/dev/null 2>&1

  # Wait for container to stop
  local max_wait=30
  local waited=0
  while [ $waited -lt $max_wait ]; do
    local status
    status=$(docker inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null)
    if [ "$status" = "exited" ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  log "Copying dump to container..."
  docker cp "$dump_file" "$container_name:/var/lib/neo4j/import/restore.dump"

  log "Running neo4j-admin restore..."
  # Get data volume
  local data_volume
  data_volume=$(docker inspect "$container_name" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')

  local import_volume
  import_volume=$(docker inspect "$container_name" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/neo4j/import"}}{{.Name}}{{end}}{{end}}')

  # Run neo4j-admin load in temporary container - show output in real-time
  # Note: neo4j-admin database load expects the dump file to be named "neo4j.dump" in the from-path directory
  if ! docker run --rm \
    -v "$data_volume:/data" \
    -v "$import_volume:/var/lib/neo4j/import" \
    --entrypoint sh \
    neo4j:5.15-community \
    -c "mv /var/lib/neo4j/import/restore.dump /var/lib/neo4j/import/neo4j.dump && neo4j-admin database load neo4j --from-path=/var/lib/neo4j/import --overwrite-destination=true"; then
    error "Failed to restore Neo4j"
    log "Restarting Neo4j container..."
    docker start "$container_name" >/dev/null 2>&1
    return 1
  fi

  log "Starting Neo4j..."
  docker start "$container_name" >/dev/null 2>&1

  # Wait for healthy
  log "Waiting for Neo4j to be healthy..."
  max_wait=60
  waited=0
  while [ $waited -lt $max_wait ]; do
    if docker ps --filter "name=$container_name" --format "{{.Status}}" | grep -q "healthy"; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  ok "Neo4j restore complete"
}

# restore_neo4j_from_targz <stack> <compose_cmd> <targz_file> [target_env]
# Restores Neo4j from a tar.gz archive of the data directory (old backup format)
restore_neo4j_from_targz() {
  local stack="$1"
  local compose_cmd="$2"
  local targz_file="$3"
  local target_env="${4:-}"

  [ -f "$targz_file" ] || fail "Tar.gz file not found: $targz_file"

  # If target_env is provided, rebuild compose_cmd for that environment
  if [ -n "$target_env" ]; then
    local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local target_env_file="$cli_root/.${target_env}.env"
    [ -f "$target_env_file" ] || fail "Target env file not found: $target_env_file"

    log "Restoring to target environment: $target_env"
    compose_cmd=$(resolve_compose_cmd "$stack" "$target_env_file" "")
  fi

  warn "This will STOP Neo4j, restore from tar.gz archive, then restart it."
  warn "This uses the old backup format (tar.gz of /data directory)"
  confirm "Continue?" || { ok "Restore cancelled"; return 0; }

  # Get container name
  local container_name
  container_name=$(docker ps -a --filter "name=neo4j" --format "{{.Names}}" | grep "$stack" | head -1)

  if [ -z "$container_name" ]; then
    error "Neo4j container not found for stack: $stack"
    return 1
  fi

  log "Using container: $container_name"
  log "Stopping Neo4j for restore..."
  docker stop "$container_name" >/dev/null 2>&1

  # Wait for container to stop
  local max_wait=30
  local waited=0
  while [ $waited -lt $max_wait ]; do
    local status
    status=$(docker inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null)
    if [ "$status" = "exited" ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  # Get data volume
  local data_volume
  data_volume=$(docker inspect "$container_name" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')

  log "Clearing existing data..."
  docker run --rm \
    -v "$data_volume:/data" \
    alpine:latest \
    sh -c "rm -rf /data/*"

  log "Extracting tar.gz archive to data volume..."
  # Get absolute path to tar.gz file
  local abs_targz_path
  abs_targz_path=$(cd "$(dirname "$targz_file")" && pwd)/$(basename "$targz_file")

  # Extract the tar.gz directly into the data volume
  docker run --rm \
    -v "$data_volume:/data" \
    -v "$(dirname "$abs_targz_path"):/backup" \
    alpine:latest \
    sh -c "cd /data && tar -xzf /backup/$(basename "$abs_targz_path") --strip-components=1"

  if [ $? -ne 0 ]; then
    error "Failed to extract tar.gz archive"
    docker start "$container_name" >/dev/null 2>&1
    return 1
  fi

  log "Starting Neo4j..."
  docker start "$container_name" >/dev/null 2>&1

  # Wait for healthy
  log "Waiting for Neo4j to be healthy..."
  max_wait=60
  waited=0
  while [ $waited -lt $max_wait ]; do
    if docker ps --filter "name=$container_name" --format "{{.Status}}" | grep -q "healthy"; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  ok "Neo4j restore from tar.gz complete"
}

# restore_postgres <stack> <compose_cmd> <sql_file> [target_env]
# Restores Postgres from a SQL file
# If target_env is provided, uses that env's compose setup (for cross-env restores)
restore_postgres() {
  local stack="$1"
  local compose_cmd="$2"
  local sql_file="$3"
  local target_env="${4:-}"  # Optional: target environment override

  [ -f "$sql_file" ] || fail "SQL file not found: $sql_file"

  # If target_env is provided, rebuild compose_cmd for that environment
  if [ -n "$target_env" ]; then
    local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local target_env_file="$cli_root/.${target_env}.env"
    [ -f "$target_env_file" ] || fail "Target env file not found: $target_env_file"

    log "Restoring to target environment: $target_env"
    compose_cmd=$(resolve_compose_cmd "$stack" "$target_env_file" "")
  fi

  warn "This will restore PostgreSQL from: $sql_file"
  confirm "Continue?" || { ok "Restore cancelled"; return 0; }

  # Resolve compose service name (default: postgres)
  local pg_service="${BACKUP_POSTGRES_SERVICE:-postgres}"

  log "Restoring PostgreSQL (service: $pg_service)..."

  # Drop and recreate the database to avoid "already exists" errors
  log "Dropping and recreating database..."
  $compose_cmd exec -T "$pg_service" \
    psql -U "${POSTGRES_USER:-postgres}" -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${POSTGRES_DB:-app_db}' AND pid <> pg_backend_pid();" \
    -c "DROP DATABASE IF EXISTS \"${POSTGRES_DB:-app_db}\";" \
    -c "CREATE DATABASE \"${POSTGRES_DB:-app_db}\";" \
  || { error "Failed to recreate database"; return 1; }

  $compose_cmd exec -T "$pg_service" \
    psql -U "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-app_db}" < "$sql_file" \
  && ok "PostgreSQL restore complete" \
  || { error "PostgreSQL restore failed"; return 1; }
}

# restore_gdrive_transcripts <stack> <compose_cmd> <tar_file>
restore_gdrive_transcripts() {
  local stack="$1"
  local compose_cmd="$2"
  local tar_file="$3"

  [ -f "$tar_file" ] || fail "Tar file not found: $tar_file"

  # Check if ch-ingest-gdrive service exists
  if ! $compose_cmd ps --services 2>/dev/null | grep -q "ch-ingest-gdrive"; then
    warn "ch-ingest-gdrive service not found in stack (may not be deployed with gdrive profile)"
    return 0
  fi

  warn "This will restore GDrive transcripts from: $tar_file"
  confirm "Continue?" || { ok "Restore cancelled"; return 0; }

  log "Restoring GDrive transcripts..."
  $compose_cmd exec -T ch-ingest-gdrive tar xzf - -C /app < "$tar_file" \
  && ok "GDrive transcripts restore complete" \
  || { error "GDrive transcripts restore failed"; return 1; }
}

# ── db_pull per-DB helpers ─────────────────────────────────────────────────────

# _db_pull_find_and_download <ssh_opts> <vps_user> <vps_host> <remote_dir> <local_dir> <pattern> <specific_file>
# Finds latest backup matching pattern on VPS and downloads it. Echoes local path.
_db_pull_find_and_download() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3"
  local remote_dir="$4" local_dir="$5" pattern="$6" specific_file="${7:-}"

  local latest
  if [ -n "$specific_file" ]; then
    latest="$remote_dir/$specific_file"
  else
    latest=$(ssh $ssh_opts "$vps_user@$vps_host" \
      "ls -t $remote_dir/$pattern 2>/dev/null | head -1" || echo "")
  fi

  [ -n "$latest" ] || return 1

  local filename
  filename=$(basename "$latest")
  local local_file="$local_dir/$filename"

  log "Downloading $filename from VPS..."
  rsync -avz -e "ssh $ssh_opts" \
    "$vps_user@$vps_host:$latest" \
    "$local_file" \
  && ok "Downloaded: $local_file" \
  || { error "Failed to download backup"; return 1; }

  echo "$local_file"
}

# _db_pull_postgres <ssh_opts> <vps_user> <vps_host> <remote_dir> <backup_dir> <compose_cmd> <download_only> <specific_file>
_db_pull_postgres() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3"
  local remote_dir="$4" backup_dir="$5" compose_cmd="$6"
  local download_only="$7" specific_file="${8:-}"

  log "Finding latest PostgreSQL backup on VPS..."
  local sf=""
  [ -n "$specific_file" ] && [[ "$specific_file" == *.sql ]] && sf="$specific_file"

  local local_file
  local_file=$(_db_pull_find_and_download "$ssh_opts" "$vps_user" "$vps_host" \
    "$remote_dir" "$backup_dir" "postgres-*.sql" "$sf") || {
    warn "No PostgreSQL backups found on VPS at $remote_dir"
    return 0
  }

  if [ "$download_only" != "true" ]; then
    log "Restoring PostgreSQL to local environment..."
    warn "This will overwrite your local PostgreSQL database"
    confirm "Continue with restore?" || { ok "Restore skipped"; return 0; }
    restore_postgres "$stack" "$compose_cmd" "$local_file"
  fi
}

# _db_pull_neo4j <ssh_opts> <vps_user> <vps_host> <remote_dir> <backup_dir> <compose_cmd> <download_only> <specific_file>
_db_pull_neo4j() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3"
  local remote_dir="$4" backup_dir="$5" compose_cmd="$6"
  local download_only="$7" specific_file="${8:-}"

  log "Finding latest Neo4j backup on VPS..."
  local sf=""
  [ -n "$specific_file" ] && [[ "$specific_file" == *.dump ]] && sf="$specific_file"

  local local_file
  local_file=$(_db_pull_find_and_download "$ssh_opts" "$vps_user" "$vps_host" \
    "$remote_dir" "$backup_dir" "neo4j-*.dump" "$sf") || {
    warn "No Neo4j backups found on VPS at $remote_dir"
    return 0
  }

  if [ "$download_only" != "true" ]; then
    log "Restoring Neo4j to local environment..."
    warn "This will stop Neo4j, restore the database, and restart it"
    confirm "Continue with restore?" || { ok "Restore skipped"; return 0; }
    restore_neo4j "$stack" "$compose_cmd" "$local_file"
  fi
}

# _db_pull_mysql <ssh_opts> <vps_user> <vps_host> <remote_dir> <backup_dir> <compose_cmd> <download_only> <target> <specific_file>
_db_pull_mysql() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3"
  local remote_dir="$4" backup_dir="$5" compose_cmd="$6"
  local download_only="$7" target="$8" specific_file="${9:-}"

  log "Finding latest MySQL backup on VPS..."
  local sf=""
  [ -n "$specific_file" ] && [[ "$specific_file" == mysql-*.sql ]] && sf="$specific_file"

  local local_file
  local_file=$(_db_pull_find_and_download "$ssh_opts" "$vps_user" "$vps_host" \
    "$remote_dir" "$backup_dir" "mysql-*.sql" "$sf") || {
    [ "$target" = "mysql" ] && warn "No MySQL backups found on VPS at $remote_dir"
    return 0
  }

  if [ "$download_only" != "true" ]; then
    log "Restoring MySQL to local environment..."
    warn "This will overwrite your local MySQL database"
    confirm "Continue with restore?" || { ok "Restore skipped"; return 0; }
    restore_mysql "$stack" "$compose_cmd" "$local_file"
  fi
}

# _db_pull_sqlite <ssh_opts> <vps_user> <vps_host> <remote_dir> <backup_dir> <compose_cmd> <download_only> <target> <specific_file>
_db_pull_sqlite() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3"
  local remote_dir="$4" backup_dir="$5" compose_cmd="$6"
  local download_only="$7" target="$8" specific_file="${9:-}"

  log "Finding latest SQLite backup on VPS..."
  local sf=""
  [ -n "$specific_file" ] && [[ "$specific_file" == sqlite-*.db ]] && sf="$specific_file"

  local local_file
  local_file=$(_db_pull_find_and_download "$ssh_opts" "$vps_user" "$vps_host" \
    "$remote_dir" "$backup_dir" "sqlite-*.db" "$sf") || {
    [ "$target" = "sqlite" ] && warn "No SQLite backups found on VPS at $remote_dir"
    return 0
  }

  if [ "$download_only" != "true" ]; then
    log "Restoring SQLite to local environment..."
    warn "This will overwrite your local SQLite database"
    confirm "Continue with restore?" || { ok "Restore skipped"; return 0; }
    restore_sqlite "$stack" "$compose_cmd" "$local_file"
  fi
}

# db_pull <stack> <target> <env_file> <download_only> <specific_file>
# Pull latest backup from VPS and optionally restore to local dev environment.
# Dispatches to _db_pull_* helpers per database type.
db_pull() {
  local stack="$1"
  local target="$2"
  local env_file="$3"
  local download_only="$4"
  local specific_file="$5"

  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a; source "$env_file"; set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local vps_deploy_dir="${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

  local backup_dir
  backup_dir=$(_backup_dir "$stack")
  mkdir -p "$backup_dir"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key")

  local remote_backup_dir
  remote_backup_dir=$(_remote_backup_dir "$stack" "$ssh_opts" "$vps_user" "$vps_host" "$vps_deploy_dir")

  # Check if local stack is running (unless download-only)
  local compose_cmd=""
  if [ "$download_only" != "true" ]; then
    log "Checking if local stack is running..."

    # Build compose command matching how local_start does it (no --project-name)
    compose_cmd=$(resolve_local_compose_cmd "$stack")

    if ! $compose_cmd ps --services --filter "status=running" 2>/dev/null | grep -q .; then
      fail "Local stack is not running. Start it first with: strut $stack local start"
    fi
  fi

  [[ "$target" == "postgres" || "$target" == "all" ]] && \
    _db_pull_postgres "$ssh_opts" "$vps_user" "$vps_host" "$remote_backup_dir" "$backup_dir" "$compose_cmd" "$download_only" "$specific_file"

  [[ "$target" == "neo4j" || "$target" == "all" ]] && \
    _db_pull_neo4j "$ssh_opts" "$vps_user" "$vps_host" "$remote_backup_dir" "$backup_dir" "$compose_cmd" "$download_only" "$specific_file"

  [[ "$target" == "mysql" || "$target" == "all" ]] && \
    _db_pull_mysql "$ssh_opts" "$vps_user" "$vps_host" "$remote_backup_dir" "$backup_dir" "$compose_cmd" "$download_only" "$target" "$specific_file"

  [[ "$target" == "sqlite" || "$target" == "all" ]] && \
    _db_pull_sqlite "$ssh_opts" "$vps_user" "$vps_host" "$remote_backup_dir" "$backup_dir" "$compose_cmd" "$download_only" "$target" "$specific_file"

  if [ "$download_only" = "true" ]; then
    ok "Download complete. Files saved to: $backup_dir"
  else
    ok "Pull and restore complete"
  fi
}

# ── db_push per-DB helpers ─────────────────────────────────────────────────────

# _db_push_upload <ssh_opts> <vps_user> <vps_host> <remote_dir> <local_file>
# Uploads a backup file to VPS. Returns 0 on success.
_db_push_upload() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3"
  local remote_dir="$4" local_file="$5"

  local filename
  filename=$(basename "$local_file")
  log "Uploading $filename to VPS..."
  rsync -avz -e "ssh $ssh_opts" \
    "$local_file" \
    "$vps_user@$vps_host:$remote_dir/" \
  && ok "Uploaded: $filename" \
  || { error "Failed to upload backup"; return 1; }
}

# _db_push_postgres <stack> <ssh_opts> <vps_user> <vps_host> <remote_dir> <backup_dir> <project_name> <_sudo> <upload_only> <specific_file>
_db_push_postgres() {
  local stack="$1" ssh_opts="$2" vps_user="$3" vps_host="$4"
  local remote_dir="$5" backup_dir="$6" project_name="$7"
  local _sudo="$8" upload_only="$9" specific_file="${10:-}"

  local local_file="$specific_file"
  if [ -z "$local_file" ]; then
    local_file=$(ls -t "$backup_dir"/postgres-*.sql 2>/dev/null | head -1)
    [ -n "$local_file" ] || fail "No local PostgreSQL backups found in $backup_dir"
  fi
  [ -f "$local_file" ] || fail "Backup file not found: $local_file"

  _db_push_upload "$ssh_opts" "$vps_user" "$vps_host" "$remote_dir" "$local_file" || return 1

  if [ "$upload_only" != "true" ]; then
    local filename
    filename=$(basename "$local_file")
    warn "⚠️  DESTRUCTIVE OPERATION: This will restore PostgreSQL on REMOTE VPS ($vps_host)"
    warn "Environment: $project_name"
    warn "File: $filename"
    echo ""
    confirm "Type 'yes' to continue with remote restore" || { ok "Restore cancelled"; return 0; }

    log "Creating safety backup on VPS before restore..."
    ssh $ssh_opts "$vps_user@$vps_host" \
      "cd ${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut} && \
       [ -f stacks/$stack/backup.conf ] && . stacks/$stack/backup.conf; \
       ${_sudo}docker compose --project-name $project_name exec -T \${BACKUP_POSTGRES_SERVICE:-postgres} \
         pg_dump -U \${POSTGRES_USER:-postgres} \${POSTGRES_DB:-app_db} > $remote_dir/pre-push-safety-$(date +%Y%m%d-%H%M%S).sql" \
    && ok "Safety backup created" \
    || warn "Failed to create safety backup (continuing anyway)"

    log "Restoring PostgreSQL on VPS..."
    if ssh $ssh_opts "$vps_user@$vps_host" \
      "cd ${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut} && \
       [ -f stacks/$stack/backup.conf ] && . stacks/$stack/backup.conf; \
       ${_sudo}docker compose --project-name $project_name exec -T \${BACKUP_POSTGRES_SERVICE:-postgres} \
         psql -U \${POSTGRES_USER:-postgres} -d \${POSTGRES_DB:-app_db} < $remote_dir/$filename"; then
      ok "PostgreSQL restore complete on VPS"
    else
      error "PostgreSQL restore failed on VPS"
      warn "Rollback: SSH to VPS and restore from safety backup in $remote_dir/pre-push-safety-*.sql"
      return 1
    fi
  fi
}

# _db_push_neo4j <stack> <ssh_opts> <vps_user> <vps_host> <remote_dir> <backup_dir> <project_name> <_sudo> <upload_only> <specific_file>
_db_push_neo4j() {
  local stack="$1" ssh_opts="$2" vps_user="$3" vps_host="$4"
  local remote_dir="$5" backup_dir="$6" project_name="$7"
  local _sudo="$8" upload_only="$9" specific_file="${10:-}"

  local local_file="$specific_file"
  if [ -z "$local_file" ]; then
    local_file=$(ls -t "$backup_dir"/neo4j-*.dump 2>/dev/null | head -1)
    [ -n "$local_file" ] || fail "No local Neo4j backups found in $backup_dir"
  fi
  [ -f "$local_file" ] || fail "Backup file not found: $local_file"

  _db_push_upload "$ssh_opts" "$vps_user" "$vps_host" "$remote_dir" "$local_file" || return 1

  if [ "$upload_only" != "true" ]; then
    local filename
    filename=$(basename "$local_file")
    warn "⚠️  DESTRUCTIVE OPERATION: This will restore Neo4j on REMOTE VPS ($vps_host)"
    warn "Environment: $project_name"
    warn "File: $filename"
    warn "Neo4j will be stopped during restore (~30s downtime)"
    echo ""
    confirm "Type 'yes' to continue with remote restore" || { ok "Restore cancelled"; return 0; }

    log "Creating safety backup on VPS before restore..."
    ssh $ssh_opts "$vps_user@$vps_host" \
      "cd ${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut} && \
       ${_sudo}docker compose --project-name $project_name exec -T neo4j \
         neo4j-admin database dump neo4j --to-path=/var/lib/neo4j/import/pre-push-safety-$(date +%Y%m%d-%H%M%S).dump" \
    2>/dev/null && ok "Safety backup created" \
    || warn "Failed to create safety backup (continuing anyway)"

    log "Restoring Neo4j on VPS (stopping service)..."
    if ssh $ssh_opts "$vps_user@$vps_host" \
      "cd ${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut} && \
       ${_sudo}docker compose --project-name $project_name cp $remote_dir/$filename neo4j:/var/lib/neo4j/import/restore.dump && \
       ${_sudo}docker compose --project-name $project_name stop neo4j && \
       ${_sudo}docker compose --project-name $project_name run --rm --entrypoint neo4j-admin neo4j \
         database load neo4j --from-path=/var/lib/neo4j/import/restore.dump --overwrite-destination && \
       ${_sudo}docker compose --project-name $project_name start neo4j"; then
      ok "Neo4j restore complete on VPS"
    else
      error "Neo4j restore failed on VPS"
      warn "Rollback: SSH to VPS and restore from safety backup"
      return 1
    fi
  fi
}

# _db_push_mysql <stack> <ssh_opts> <vps_user> <vps_host> <remote_dir> <backup_dir> <_sudo> <upload_only> <target> <specific_file>
_db_push_mysql() {
  local stack="$1" ssh_opts="$2" vps_user="$3" vps_host="$4"
  local remote_dir="$5" backup_dir="$6" _sudo="$7"
  local upload_only="$8" target="$9" specific_file="${10:-}"

  local local_file="$specific_file"
  if [ -z "$local_file" ]; then
    local_file=$(ls -t "$backup_dir"/mysql-*.sql 2>/dev/null | head -1)
    if [ -z "$local_file" ] && [ "$target" = "all" ]; then
      return 0  # skip silently for 'all'
    fi
    [ -n "$local_file" ] || fail "No local MySQL backups found in $backup_dir"
  fi
  [ -f "$local_file" ] || return 0

  _db_push_upload "$ssh_opts" "$vps_user" "$vps_host" "$remote_dir" "$local_file" || return 1

  if [ "$upload_only" != "true" ]; then
    local filename
    filename=$(basename "$local_file")
    warn "⚠️  DESTRUCTIVE OPERATION: This will restore MySQL on REMOTE VPS ($vps_host)"
    echo ""
    confirm "Type 'yes' to continue with remote restore" || { ok "Restore cancelled"; return 0; }

    local mysql_container="${MYSQL_CONTAINER_NAME:-}"
    local mysql_db="${MYSQL_DATABASE:-}"
    local mysql_user="${MYSQL_USER:-root}"
    local mysql_password="${MYSQL_ROOT_PASSWORD:-${MYSQL_PASSWORD:-}}"

    log "Restoring MySQL on VPS..."
    if ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}docker exec -i $mysql_container \
        mysql -u $mysql_user --password=$mysql_password $mysql_db < $remote_dir/$filename"; then
      ok "MySQL restore complete on VPS"
    else
      error "MySQL restore failed on VPS"
      return 1
    fi
  fi
}

# _db_push_sqlite <stack> <ssh_opts> <vps_user> <vps_host> <remote_dir> <backup_dir> <_sudo> <upload_only> <target> <specific_file>
_db_push_sqlite() {
  local stack="$1" ssh_opts="$2" vps_user="$3" vps_host="$4"
  local remote_dir="$5" backup_dir="$6" _sudo="$7"
  local upload_only="$8" target="$9" specific_file="${10:-}"

  local local_file="$specific_file"
  if [ -z "$local_file" ]; then
    local_file=$(ls -t "$backup_dir"/sqlite-*.db 2>/dev/null | head -1)
    if [ -z "$local_file" ] && [ "$target" = "all" ]; then
      return 0  # skip silently for 'all'
    fi
    [ -n "$local_file" ] || fail "No local SQLite backups found in $backup_dir"
  fi
  [ -f "$local_file" ] || return 0

  _db_push_upload "$ssh_opts" "$vps_user" "$vps_host" "$remote_dir" "$local_file" || return 1

  if [ "$upload_only" != "true" ]; then
    local filename
    filename=$(basename "$local_file")

    local backup_conf="$CLI_ROOT/stacks/$stack/backup.conf"
    local sqlite_path="${BACKUP_SQLITE_PATH:-}"
    if [ -z "$sqlite_path" ] && [ -f "$backup_conf" ]; then
      sqlite_path=$(grep '^BACKUP_SQLITE_PATH=' "$backup_conf" | cut -d= -f2-)
    fi
    [ -n "$sqlite_path" ] || fail "BACKUP_SQLITE_PATH not set in backup.conf"

    warn "⚠️  DESTRUCTIVE OPERATION: This will restore SQLite on REMOTE VPS ($vps_host)"
    echo ""
    confirm "Type 'yes' to continue with remote restore" || { ok "Restore cancelled"; return 0; }

    log "Restoring SQLite on VPS..."
    if ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}cp '$remote_dir/$filename' '$sqlite_path'"; then
      ok "SQLite restore complete on VPS"
    else
      error "SQLite restore failed on VPS"
      return 1
    fi
  fi
}

# db_push <stack> <target> <env_file> <upload_only> <specific_file>
# Upload local backup to VPS and optionally restore it remotely.
# Dispatches to _db_push_* helpers per database type.
db_push() {
  local stack="$1"
  local target="$2"
  local env_file="$3"
  local upload_only="$4"
  local specific_file="$5"

  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a; source "$env_file"; set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local vps_deploy_dir="${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

  local backup_dir
  backup_dir=$(_backup_dir "$stack")

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key")

  local remote_backup_dir
  remote_backup_dir=$(_remote_backup_dir "$stack" "$ssh_opts" "$vps_user" "$vps_host" "$vps_deploy_dir")

  local env_name
  env_name=$(extract_env_name "$env_file")
  local project_name="${stack}-${env_name}"

  local _sudo
  _sudo="$(vps_sudo_prefix)"

  # Check if remote stack is running (unless upload-only)
  if [ "$upload_only" != "true" ]; then
    log "Checking if remote stack is running on VPS..."
    if ! ssh $ssh_opts "$vps_user@$vps_host" \
      "cd $vps_deploy_dir && ${_sudo}docker compose --project-name $project_name ps --services --filter 'status=running'" \
      2>/dev/null | grep -q .; then
      fail "Remote stack is not running on VPS. Start it first with: strut $stack deploy --env $env_name"
    fi
  fi

  [[ "$target" == "postgres" || "$target" == "all" ]] && \
    _db_push_postgres "$stack" "$ssh_opts" "$vps_user" "$vps_host" "$remote_backup_dir" "$backup_dir" "$project_name" "$_sudo" "$upload_only" "$specific_file"

  [[ "$target" == "neo4j" || "$target" == "all" ]] && \
    _db_push_neo4j "$stack" "$ssh_opts" "$vps_user" "$vps_host" "$remote_backup_dir" "$backup_dir" "$project_name" "$_sudo" "$upload_only" "$specific_file"

  [[ "$target" == "mysql" || "$target" == "all" ]] && \
    _db_push_mysql "$stack" "$ssh_opts" "$vps_user" "$vps_host" "$remote_backup_dir" "$backup_dir" "$_sudo" "$upload_only" "$target" "$specific_file"

  [[ "$target" == "sqlite" || "$target" == "all" ]] && \
    _db_push_sqlite "$stack" "$ssh_opts" "$vps_user" "$vps_host" "$remote_backup_dir" "$backup_dir" "$_sudo" "$upload_only" "$target" "$specific_file"

  if [ "$upload_only" = "true" ]; then
    ok "Upload complete. Files available at: $vps_host:$remote_backup_dir/"
  else
    ok "Push and restore complete on VPS"
  fi
}


# ============================================================
# Extended Backup CLI Functions (Phase 2 Enhancements)
# ============================================================

# backup_verify_cmd <stack> <backup_file> <compose_cmd> [--full]
# CLI command to verify a specific backup
backup_verify_cmd() {
  local stack="$1"
  local backup_file="$2"
  local compose_cmd="$3"
  local full_flag="${4:-}"

  log "Starting backup verification..."

  if verify_backup "$stack" "$backup_file" "$compose_cmd" "$full_flag"; then
    ok "Backup verification completed successfully"
    return 0
  else
    error "Backup verification failed"
    return 1
  fi
}

# backup_verify_all_cmd <stack> <compose_cmd>
# CLI command to verify all backups
backup_verify_all_cmd() {
  local stack="$1"
  local compose_cmd="$2"

  log "Starting verification of all backups..."

  if verify_all_backups "$stack" "$compose_cmd"; then
    ok "All backups verified successfully"
    return 0
  else
    error "Some backups failed verification"
    return 1
  fi
}

# backup_list_cmd <stack> [--json]
# CLI command to list all backups with metadata
backup_list_cmd() {
  local stack="$1"
  local json_flag="${2:-}"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local backup_dir="$cli_root/stacks/$stack/backups"
  local metadata_dir="$backup_dir/metadata"

  [ -d "$backup_dir" ] || { error "Backup directory not found: $backup_dir"; return 1; }

  if [ "$json_flag" = "--json" ]; then
    # JSON output
    echo "["
    local first=true

    for metadata_file in "$metadata_dir"/*.json; do
      [ -f "$metadata_file" ] || continue

      [ "$first" = false ] && echo ","
      cat "$metadata_file"
      first=false
    done 2>/dev/null

    echo "]"
  else
    # Human-readable output
    log "Backups for stack: $stack"
    echo ""

    local total=0

    # List postgres backups
    for backup_file in "$backup_dir"/postgres-*.sql; do
      [ -f "$backup_file" ] || continue
      total=$((total + 1))

      local filename
      filename=$(basename "$backup_file")
      local backup_id="${filename%.*}"
      local metadata_file="$metadata_dir/${backup_id}.json"

      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "Backup: $filename"
      echo "Service: postgres"

      local size
      size=$(du -h "$backup_file" | awk '{print $1}')
      echo "Size: $size"

      local age
      age=$(calculate_backup_age "$backup_file")
      echo "Age: $age days"

      if [ -f "$metadata_file" ] && command -v jq &>/dev/null; then
        local verification_status
        verification_status=$(jq -r '.verification.status' "$metadata_file" 2>/dev/null)
        echo "Verification: $verification_status"
      fi

      echo ""
    done

    # List neo4j backups
    for backup_file in "$backup_dir"/neo4j-*.dump; do
      [ -f "$backup_file" ] || continue
      total=$((total + 1))

      local filename
      filename=$(basename "$backup_file")
      local backup_id="${filename%.*}"
      local metadata_file="$metadata_dir/${backup_id}.json"

      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "Backup: $filename"
      echo "Service: neo4j"

      local size
      size=$(du -h "$backup_file" | awk '{print $1}')
      echo "Size: $size"

      local age
      age=$(calculate_backup_age "$backup_file")
      echo "Age: $age days"

      if [ -f "$metadata_file" ] && command -v jq &>/dev/null; then
        local verification_status
        verification_status=$(jq -r '.verification.status' "$metadata_file" 2>/dev/null)
        echo "Verification: $verification_status"
      fi

      echo ""
    done

    # List mysql backups
    for backup_file in "$backup_dir"/mysql-*.sql; do
      [ -f "$backup_file" ] || continue
      total=$((total + 1))

      local filename
      filename=$(basename "$backup_file")
      local backup_id="${filename%.*}"
      local metadata_file="$metadata_dir/${backup_id}.json"

      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "Backup: $filename"
      echo "Service: mysql"

      local size
      size=$(du -h "$backup_file" | awk '{print $1}')
      echo "Size: $size"

      local age
      age=$(calculate_backup_age "$backup_file")
      echo "Age: $age days"

      if [ -f "$metadata_file" ] && command -v jq &>/dev/null; then
        local verification_status
        verification_status=$(jq -r '.verification.status' "$metadata_file" 2>/dev/null)
        echo "Verification: $verification_status"
      fi

      echo ""
    done

    # List sqlite backups
    for backup_file in "$backup_dir"/sqlite-*.db; do
      [ -f "$backup_file" ] || continue
      total=$((total + 1))

      local filename
      filename=$(basename "$backup_file")
      local backup_id="${filename%.*}"
      local metadata_file="$metadata_dir/${backup_id}.json"

      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "Backup: $filename"
      echo "Service: sqlite"

      local size
      size=$(du -h "$backup_file" | awk '{print $1}')
      echo "Size: $size"

      local age
      age=$(calculate_backup_age "$backup_file")
      echo "Age: $age days"

      if [ -f "$metadata_file" ] && command -v jq &>/dev/null; then
        local verification_status
        verification_status=$(jq -r '.verification.status' "$metadata_file" 2>/dev/null)
        echo "Verification: $verification_status"
      fi

      echo ""
    done

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Total backups: $total"
  fi
}

# backup_health_cmd <stack> [service] [--json]
# CLI command to show backup health status
backup_health_cmd() {
  local stack="$1"
  local service="${2:-all}"
  local json_flag="${3:-}"

  if [ "$service" = "all" ]; then
    if [ "$json_flag" = "--json" ]; then
      generate_health_dashboard_data "$stack"
      cat "$CLI_ROOT/stacks/$stack/backups/health-dashboard.json"
    else
      get_all_backup_health "$stack"
    fi
  else
    if [ "$json_flag" = "--json" ]; then
      get_backup_health_json "$stack" "$service"
    else
      get_backup_health_status "$stack" "$service"
    fi
  fi
}

# backup_schedule_set_cmd <stack> <service> <cron_expression> [env_name]
# CLI command to set backup schedule
backup_schedule_set_cmd() {
  local stack="$1"
  local service="$2"
  local cron_expr="$3"
  local env_name="${4:-prod}"

  log "Setting backup schedule for $stack/$service..."

  if install_backup_schedule "$stack" "$service" "$cron_expr" "$env_name"; then
    ok "Backup schedule configured successfully"
    return 0
  else
    error "Failed to configure backup schedule"
    return 1
  fi
}

# backup_schedule_list_cmd <stack>
# CLI command to list backup schedules
backup_schedule_list_cmd() {
  local stack="$1"

  list_backup_schedules "$stack"
}

# backup_schedule_install_defaults_cmd <stack> [env_name]
# CLI command to install default schedules from backup.conf
backup_schedule_install_defaults_cmd() {
  local stack="$1"
  local env_name="${2:-prod}"

  log "Installing default backup schedules..."

  if install_default_schedules "$stack" "$env_name"; then
    ok "Default schedules installed successfully"
    return 0
  else
    error "Failed to install default schedules"
    return 1
  fi
}

# backup_retention_enforce_cmd <stack> [service]
# CLI command to enforce retention policy
backup_retention_enforce_cmd() {
  local stack="$1"
  local service="${2:-all}"

  log "Enforcing retention policy..."

  if [ "$service" = "all" ]; then
    enforce_retention_all "$stack"
  else
    enforce_retention_policy "$stack" "$service"
  fi
}

# backup_retention_install_cron_cmd <stack>
# CLI command to install retention cron job
backup_retention_install_cron_cmd() {
  local stack="$1"

  log "Installing retention policy cron job..."

  if install_retention_cron "$stack"; then
    ok "Retention cron job installed successfully"
    return 0
  else
    error "Failed to install retention cron job"
    return 1
  fi
}

# backup_storage_stats_cmd <stack>
# CLI command to show storage statistics
backup_storage_stats_cmd() {
  local stack="$1"

  get_backup_storage_stats "$stack"
  echo ""
  check_storage_capacity "$stack" || true  # Don't fail if storage is OK
}

# backup_check_missed_cmd <stack>
# CLI command to check for missed backups
backup_check_missed_cmd() {
  local stack="$1"

  check_missed_backups "$stack"
}
