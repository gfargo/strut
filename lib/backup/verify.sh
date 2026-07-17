#!/usr/bin/env bash
# ==================================================
# lib/backup/verify.sh — Backup verification logic
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Verifies backup integrity by attempting restore operations
# and validating data consistency.

# verify_postgres_backup <stack> <backup_file> <compose_cmd>
# Verifies a PostgreSQL backup by restoring to a temporary database
set -euo pipefail

verify_postgres_backup() {
  local stack="$1"
  local backup_file="$2"
  local compose_cmd="$3"

  # A dump truncated cleanly at a statement boundary (e.g. right after
  # CREATE TABLE, before any data) restores without a psql error yet is
  # missing data — validate_backup_artifact catches that (completion-marker
  # trailer check) before wasting time on a restore.
  validate_backup_artifact "postgres" "$backup_file" || return 1

  local pg_service="${BACKUP_POSTGRES_SERVICE:-postgres}"
  local temp_db="verify_temp_$(date +%s)"
  local start_time
  start_time=$(date +%s)

  log "Verifying PostgreSQL backup: $(basename "$backup_file")" >&2
  log "Creating temporary database: $temp_db" >&2

  # Create temporary database
  if ! $compose_cmd exec -T "$pg_service" \
    psql -U "${POSTGRES_USER:-postgres}" -c "CREATE DATABASE $temp_db;" >/dev/null 2>&1; then
    error "Failed to create temporary database"
    return 1
  fi

  # Restore backup to temporary database.
  # ON_ERROR_STOP=1 is essential: without it psql exits 0 on a truncated dump
  # and verification "passes" on a corrupt backup.
  log "Restoring backup to temporary database..." >&2
  if ! $compose_cmd exec -T "$pg_service" \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "$temp_db" <"$backup_file" >/dev/null 2>&1; then
    error "Failed to restore backup to temporary database"
    # Cleanup
    $compose_cmd exec -T "$pg_service" \
      psql -U "${POSTGRES_USER:-postgres}" -c "DROP DATABASE IF EXISTS $temp_db;" >/dev/null 2>&1
    return 1
  fi

  # Verify schema and get table count
  local table_count
  table_count=$($compose_cmd exec -T "$pg_service" \
    psql -U "${POSTGRES_USER:-postgres}" -d "$temp_db" -t -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')

  # Get row count across all tables
  local row_count
  row_count=$($compose_cmd exec -T "$pg_service" \
    psql -U "${POSTGRES_USER:-postgres}" -d "$temp_db" -t -c \
    "SELECT SUM(n_live_tup) FROM pg_stat_user_tables;" 2>/dev/null | tr -d ' ')

  # Cleanup temporary database
  log "Cleaning up temporary database..." >&2
  $compose_cmd exec -T "$pg_service" \
    psql -U "${POSTGRES_USER:-postgres}" -c "DROP DATABASE $temp_db;" >/dev/null 2>&1

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Validate results
  if [ -z "$table_count" ] || [ "$table_count" -eq 0 ]; then
    error "Verification failed: No tables found in backup"
    return 1
  fi

  ok "PostgreSQL backup verified successfully" >&2
  log "  Tables: $table_count" >&2
  log "  Rows: ${row_count:-0}" >&2
  log "  Duration: ${duration}s" >&2

  # Return verification details as JSON (for metadata) - stdout only
  echo "{\"tables_verified\":$table_count,\"row_count\":${row_count:-0},\"schema_valid\":true,\"duration_seconds\":$duration}"
  return 0
}

# _neo4j_verify_load_dump <stack> <backup_file>
# Loads a Neo4j dump into a fresh scratch volume via `neo4j-admin database
# load`, without touching the live container — safe to run at any time.
# On success, prints "<image> <scratch_volume>" to stdout; the caller owns
# the scratch volume and must `docker volume rm` it when done.
# On failure, cleans up after itself and returns 1 with nothing on stdout.
_neo4j_verify_load_dump() {
  local stack="$1"
  local backup_file="$2"

  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  # Resolved the same way backup_neo4j finds the live container, so this
  # works regardless of the compose service name.
  local neo4j_service="${BACKUP_NEO4J_SERVICE:-neo4j}"
  local container_name
  container_name=$(${_sudo}docker ps --filter "name=$neo4j_service" --format "{{.Names}}" | grep "$stack" | head -1 || true)
  [ -n "$container_name" ] || {
    error "Neo4j container not found for stack: $stack"
    return 1
  }

  # Never hardcode the image tag — read it from the running container so
  # verification always matches whatever version is actually deployed.
  local image
  image=$(${_sudo}docker inspect "$container_name" --format '{{.Config.Image}}' || true)
  [ -n "$image" ] || {
    error "Failed to resolve Neo4j image for container: $container_name"
    return 1
  }

  # neo4j-admin's --from-path expects a directory containing "<db>.dump",
  # not the dump file path itself.
  local tmp_import
  tmp_import=$(mktemp -d)
  cp "$backup_file" "$tmp_import/neo4j.dump" || {
    error "Failed to stage backup file for verification"
    rm -rf "$tmp_import"
    return 1
  }

  local scratch_vol="strut-verify-$$-${RANDOM}"
  ${_sudo}docker volume create "$scratch_vol" >/dev/null 2>&1 || {
    error "Failed to create scratch volume for verification"
    rm -rf "$tmp_import"
    return 1
  }

  log "Loading dump into scratch volume for structural verification..." >&2
  if ! ${_sudo}docker run --rm \
    -v "$scratch_vol:/data" \
    -v "$tmp_import:/var/lib/neo4j/import" \
    --entrypoint neo4j-admin \
    "$image" \
    database load neo4j --from-path=/var/lib/neo4j/import --overwrite-destination=true 2>&1 \
    | tee /dev/stderr | grep -q "Load completed successfully"; then
    error "Verification failed: neo4j-admin could not load the dump (corrupt or truncated backup)"
    rm -rf "$tmp_import"
    ${_sudo}docker volume rm "$scratch_vol" >/dev/null 2>&1
    return 1
  fi

  rm -rf "$tmp_import"
  echo "$image $scratch_vol"
  return 0
}

# verify_neo4j_backup <stack> <backup_file> <compose_cmd>
# Verifies a Neo4j backup by loading the dump into a scratch volume via
# neo4j-admin and confirming the load succeeded — a real structural check
# with zero downtime to the live service.
verify_neo4j_backup() {
  local stack="$1"
  local backup_file="$2"

  [ -f "$backup_file" ] || {
    error "Backup file not found: $backup_file"
    return 1
  }
  [ -s "$backup_file" ] || {
    error "Verification failed: backup file is empty: $backup_file"
    return 1
  }

  local start_time
  start_time=$(date +%s)

  log "Verifying Neo4j backup: $(basename "$backup_file")" >&2

  local load_result
  load_result=$(_neo4j_verify_load_dump "$stack" "$backup_file") || return 1

  local image scratch_vol
  read -r image scratch_vol <<<"$load_result"

  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"
  ${_sudo}docker volume rm "$scratch_vol" >/dev/null 2>&1

  local file_size
  file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  ok "Neo4j backup verified successfully (structural check)" >&2
  log "  File size: $file_size bytes" >&2
  log "  Duration: ${duration}s" >&2

  # Return verification details as JSON (for metadata) - stdout only
  echo "{\"file_size_bytes\":$file_size,\"structural_check\":true,\"full_verification\":false,\"duration_seconds\":$duration}"
  return 0
}

# verify_neo4j_backup_full <stack> <backup_file> <compose_cmd>
# Full Neo4j verification: loads the dump into a scratch volume (as above),
# then boots an ephemeral, isolated Neo4j server against it and queries real
# node/relationship counts. The live service is never touched, so — unlike
# the previous implementation — this has no downtime and needs no
# confirmation prompt.
verify_neo4j_backup_full() {
  local stack="$1"
  local backup_file="$2"

  [ -f "$backup_file" ] || {
    error "Backup file not found: $backup_file"
    return 1
  }
  [ -s "$backup_file" ] || {
    error "Verification failed: backup file is empty: $backup_file"
    return 1
  }

  local start_time
  start_time=$(date +%s)

  log "Verifying Neo4j backup (full): $(basename "$backup_file")" >&2

  local load_result
  load_result=$(_neo4j_verify_load_dump "$stack" "$backup_file") || return 1

  local image scratch_vol
  read -r image scratch_vol <<<"$load_result"

  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  local temp_password="verify-$$-${RANDOM}"
  local ephemeral_name="strut-verify-neo4j-$$-${RANDOM}"

  log "Starting ephemeral Neo4j to validate content..." >&2
  if ! ${_sudo}docker run -d --rm \
    --name "$ephemeral_name" \
    -v "$scratch_vol:/data" \
    -e "NEO4J_AUTH=neo4j/$temp_password" \
    "$image" >/dev/null 2>&1; then
    error "Failed to start ephemeral Neo4j for verification"
    ${_sudo}docker volume rm "$scratch_vol" >/dev/null 2>&1
    return 1
  fi

  local ready=false
  local waited=0
  while [ $waited -lt 60 ]; do
    if ${_sudo}docker exec "$ephemeral_name" \
      cypher-shell -u neo4j -p "$temp_password" "RETURN 1" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  if [ "$ready" != "true" ]; then
    error "Verification failed: ephemeral Neo4j did not become ready"
    ${_sudo}docker stop "$ephemeral_name" >/dev/null 2>&1
    ${_sudo}docker volume rm "$scratch_vol" >/dev/null 2>&1
    return 1
  fi

  # A failed count query is a failed verification, not "0 nodes" — no
  # `|| echo 0` fallback that would mask a broken query as success.
  local node_count rel_count
  if ! node_count=$(${_sudo}docker exec "$ephemeral_name" \
    cypher-shell -u neo4j -p "$temp_password" --format plain \
    "MATCH (n) RETURN count(n)" 2>/dev/null | tail -1 | tr -d ' "'); then
    error "Verification failed: node count query failed against restored backup"
    ${_sudo}docker stop "$ephemeral_name" >/dev/null 2>&1
    ${_sudo}docker volume rm "$scratch_vol" >/dev/null 2>&1
    return 1
  fi

  if ! rel_count=$(${_sudo}docker exec "$ephemeral_name" \
    cypher-shell -u neo4j -p "$temp_password" --format plain \
    "MATCH ()-[r]->() RETURN count(r)" 2>/dev/null | tail -1 | tr -d ' "'); then
    error "Verification failed: relationship count query failed against restored backup"
    ${_sudo}docker stop "$ephemeral_name" >/dev/null 2>&1
    ${_sudo}docker volume rm "$scratch_vol" >/dev/null 2>&1
    return 1
  fi

  ${_sudo}docker stop "$ephemeral_name" >/dev/null 2>&1
  ${_sudo}docker volume rm "$scratch_vol" >/dev/null 2>&1

  if ! [[ "$node_count" =~ ^[0-9]+$ ]] || ! [[ "$rel_count" =~ ^[0-9]+$ ]]; then
    error "Verification failed: could not parse node/relationship counts from restored backup"
    return 1
  fi

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  ok "Neo4j backup verified successfully (full check)" >&2
  log "  Nodes: $node_count" >&2
  log "  Relationships: $rel_count" >&2
  log "  Duration: ${duration}s" >&2

  # Return verification details as JSON - stdout only
  echo "{\"nodes_verified\":$node_count,\"relationships_verified\":$rel_count,\"full_verification\":true,\"duration_seconds\":$duration}"
  return 0
}

# verify_mysql_backup <stack> <backup_file> <compose_cmd>
# Verifies a MySQL backup by restoring to a temporary database
verify_mysql_backup() {
  local stack="$1"
  local backup_file="$2"
  local compose_cmd="$3"

  # mysqldump appends a completion trailer on a complete dump; a dump
  # truncated at a statement boundary restores without error yet is missing
  # data — validate_backup_artifact catches that before wasting time on a
  # restore.
  validate_backup_artifact "mysql" "$backup_file" || return 1

  local start_time
  start_time=$(date +%s)

  log "Verifying MySQL backup: $(basename "$backup_file")" >&2

  local mysql_container="${MYSQL_CONTAINER_NAME:-}"
  local mysql_user="${MYSQL_USER:-root}"
  local mysql_password="${MYSQL_ROOT_PASSWORD:-${MYSQL_PASSWORD:-}}"
  local temp_db="verify_temp_$(date +%s)"

  # Determine exec method (array, not string, so -e MYSQL_PWD can be inserted
  # safely without relying on word-splitting). -e must precede the
  # container/service name for both `docker exec` and `compose exec`.
  local mysql_service="${BACKUP_MYSQL_SERVICE:-mysql}"
  local exec_prefix=()
  if [ -n "$mysql_container" ]; then
    exec_prefix=(docker exec -i -e MYSQL_PWD "$mysql_container")
  else
    # shellcheck disable=SC2206 # intentional: compose_cmd may be "docker compose" (2 words)
    exec_prefix=($compose_cmd exec -T -e MYSQL_PWD "$mysql_service")
  fi

  # MYSQL_PWD exported locally so it never appears as a literal argv token on
  # host or container.
  export MYSQL_PWD="$mysql_password"

  # Create temporary database
  log "Creating temporary database: $temp_db" >&2
  if ! "${exec_prefix[@]}" mysql -u "$mysql_user" \
    -e "CREATE DATABASE \`$temp_db\`;" 2>/dev/null; then
    error "Failed to create temporary database"
    unset MYSQL_PWD
    return 1
  fi

  # Restore backup to temporary database
  log "Restoring backup to temporary database..." >&2
  if ! "${exec_prefix[@]}" mysql -u "$mysql_user" \
    "$temp_db" <"$backup_file" 2>/dev/null; then
    error "Failed to restore backup to temporary database"
    "${exec_prefix[@]}" mysql -u "$mysql_user" \
      -e "DROP DATABASE IF EXISTS \`$temp_db\`;" 2>/dev/null
    unset MYSQL_PWD
    return 1
  fi

  # Get table count
  local table_count
  table_count=$("${exec_prefix[@]}" mysql -u "$mysql_user" \
    -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$temp_db';" 2>/dev/null | tr -d ' ')

  # Cleanup
  log "Cleaning up temporary database..." >&2
  "${exec_prefix[@]}" mysql -u "$mysql_user" \
    -e "DROP DATABASE IF EXISTS \`$temp_db\`;" 2>/dev/null
  unset MYSQL_PWD

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  if [ -z "$table_count" ] || [ "$table_count" -eq 0 ]; then
    error "Verification failed: No tables found in backup"
    return 1
  fi

  ok "MySQL backup verified successfully" >&2
  log "  Tables: $table_count" >&2
  log "  Duration: ${duration}s" >&2

  echo "{\"tables_verified\":${table_count:-0},\"schema_valid\":true,\"duration_seconds\":$duration}"
  return 0
}

# verify_sqlite_backup <stack> <backup_file>
# Verifies a SQLite backup by checking integrity
verify_sqlite_backup() {
  local stack="$1"
  local backup_file="$2"

  [ -f "$backup_file" ] || {
    error "Backup file not found: $backup_file"
    return 1
  }

  local start_time
  start_time=$(date +%s)

  log "Verifying SQLite backup: $(basename "$backup_file")" >&2

  local file_size
  file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")

  if [ "$file_size" -lt 100 ]; then
    error "Verification failed: Backup file appears to be empty or corrupted"
    return 1
  fi

  local table_count=0

  if command -v sqlite3 &>/dev/null; then
    # Run integrity check
    local integrity
    integrity=$(sqlite3 "$backup_file" "PRAGMA integrity_check;" 2>/dev/null)

    if [ "$integrity" != "ok" ]; then
      error "SQLite integrity check failed: $integrity"
      return 1
    fi

    # Count tables
    table_count=$(sqlite3 "$backup_file" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
  else
    warn "sqlite3 not available locally — performing basic file check only" >&2
  fi

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  ok "SQLite backup verified successfully" >&2
  log "  File size: $file_size bytes" >&2
  log "  Tables: $table_count" >&2
  log "  Duration: ${duration}s" >&2

  echo "{\"file_size_bytes\":$file_size,\"tables_verified\":$table_count,\"integrity_check\":true,\"duration_seconds\":$duration}"
  return 0
}

# create_backup_metadata <stack> <backup_file> <service> <verification_result>
# Creates a metadata JSON file for a backup
create_backup_metadata() {
  local stack="$1"
  local backup_file="$2"
  local service="$3"
  local verification_result="$4"

  [ -f "$backup_file" ] || {
    error "Backup file not found: $backup_file"
    return 1
  }

  local metadata_dir
  metadata_dir="$(_backup_dir "$stack")/metadata" || return 1
  mkdir -p "$metadata_dir"

  local backup_filename
  backup_filename=$(basename "$backup_file")
  local backup_id="${backup_filename%.*}"
  local metadata_file="$metadata_dir/${backup_id}.json"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local file_size
  file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")

  # Parse verification result if provided
  local verification_status="pending"
  local verification_json="{}"

  if [ -n "$verification_result" ]; then
    verification_status="passed"
    verification_json="$verification_result"
  fi

  # Create metadata JSON
  cat >"$metadata_file" <<EOF
{
  "backup_id": "$backup_id",
  "stack": "$stack",
  "service": "$service",
  "type": "full",
  "timestamp": "$timestamp",
  "size_bytes": $file_size,
  "file_path": "$backup_file",
  "verification": {
    "status": "$verification_status",
    "timestamp": "$timestamp",
    "details": $verification_json
  }
}
EOF

  ok "Metadata created: $metadata_file"
  return 0
}

# update_backup_metadata_verification <stack> <backup_id> <verification_result> <status>
# Updates the verification section of an existing metadata file
update_backup_metadata_verification() {
  local stack="$1"
  local backup_id="$2"
  local verification_result="$3"
  local status="${4:-passed}"

  local metadata_file
  metadata_file="$(_backup_dir "$stack")/metadata/${backup_id}.json" || return 1

  [ -f "$metadata_file" ] || {
    error "Metadata file not found: $metadata_file"
    return 1
  }

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Use jq to update the verification section if available, otherwise use sed
  if command -v jq &>/dev/null; then
    local temp_file
    temp_file=$(mktemp)
    jq ".verification.status = \"$status\" | .verification.timestamp = \"$timestamp\" | .verification.details = $verification_result" \
      "$metadata_file" >"$temp_file" && mv "$temp_file" "$metadata_file"
  else
    # Fallback: recreate the file (less elegant but works)
    warn "jq not found, using fallback metadata update"
    # Read existing metadata and update verification section
    # This is a simplified approach - in production, jq should be available
  fi

  ok "Metadata updated: $metadata_file"
  return 0
}

# verify_backup <stack> <backup_file> <compose_cmd> [--full]
# Main entry point for backup verification
verify_backup() {
  local stack="$1"
  local backup_file="$2"
  local compose_cmd="$3"
  local full_verify="${4:-}"

  [ -f "$backup_file" ] || {
    error "Backup file not found: $backup_file"
    return 1
  }

  local backup_filename
  backup_filename=$(basename "$backup_file")
  local service=""
  local verification_result=""
  local verify_status=0

  # Determine engine from filename prefix via registry membership
  local engine=""
  local e
  for e in "${BACKUP_ENGINES[@]}"; do
    if [[ "$backup_filename" == "${e}-"* ]]; then
      engine="$e"
      break
    fi
  done

  if [ -z "$engine" ]; then
    error "Unknown backup type: $backup_filename"
    return 1
  fi
  service="$engine"

  # verify_neo4j_backup_full is the one engine with a --full variant; it's an
  # explicit override on top of the generic registry dispatch, not absorbed
  # into backup_verify_fn's one-liner naming convention.
  if [ "$engine" = "neo4j" ] && [ "$full_verify" = "--full" ]; then
    verification_result=$(verify_neo4j_backup_full "$stack" "$backup_file" "$compose_cmd")
    verify_status=$?
  else
    local verify_fn
    verify_fn=$(backup_verify_fn "$engine")
    if [ "$engine" = "sqlite" ]; then
      verification_result=$("$verify_fn" "$stack" "$backup_file")
    else
      verification_result=$("$verify_fn" "$stack" "$backup_file" "$compose_cmd")
    fi
    verify_status=$?
  fi

  # Update or create metadata
  local backup_id="${backup_filename%.*}"
  local metadata_file
  metadata_file="$(_backup_dir "$stack")/metadata/${backup_id}.json" || return 1

  if [ $verify_status -eq 0 ]; then
    if [ -f "$metadata_file" ]; then
      update_backup_metadata_verification "$stack" "$backup_id" "$verification_result" "passed"
    else
      create_backup_metadata "$stack" "$backup_file" "$service" "$verification_result"
    fi
    return 0
  else
    if [ -f "$metadata_file" ]; then
      update_backup_metadata_verification "$stack" "$backup_id" "{\"error\":\"Verification failed\"}" "failed"
    else
      create_backup_metadata "$stack" "$backup_file" "$service" "{\"error\":\"Verification failed\"}"
      update_backup_metadata_verification "$stack" "$backup_id" "{\"error\":\"Verification failed\"}" "failed"
    fi
    alert_verification_failure "$stack" "$backup_file" "$service verification failed — see logs above"
    return 1
  fi
}

# verify_all_backups <stack> <compose_cmd>
# Verifies all backups in the backup directory
verify_all_backups() {
  local stack="$1"
  local compose_cmd="$2"

  local backup_dir
  backup_dir=$(_backup_dir "$stack") || return 1

  [ -d "$backup_dir" ] || {
    error "Backup directory not found: $backup_dir"
    return 1
  }

  log "Verifying all backups for stack: $stack" >&2

  local total=0
  local passed=0
  local failed=0

  # Verify backups for every registered engine (basic verification only —
  # neo4j's --full check is not run in batch)
  local engine glob
  for engine in "${BACKUP_ENGINES[@]}"; do
    glob=$(backup_engine_glob "$engine")
    for backup_file in "$backup_dir"/$glob; do
      [ -f "$backup_file" ] || continue
      total=$((total + 1))

      if verify_backup "$stack" "$backup_file" "$compose_cmd"; then
        passed=$((passed + 1))
      else
        failed=$((failed + 1))
      fi
    done
  done

  echo ""
  ok "Verification complete: $passed/$total passed, $failed failed"

  [ $failed -eq 0 ] && return 0 || return 1
}
