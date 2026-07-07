#!/usr/bin/env bash
# ==================================================
# lib/backup/rehearsal.sh — Non-destructive restore rehearsal
# ==================================================
# Provides:
#   restore_rehearsal_postgres  — restore to a scratch DB, diff vs live, drop scratch
#   backup_verify_after         — verify a backup can actually restore

set -euo pipefail

# restore_rehearsal_postgres <stack> <compose_cmd> <sql_file>
#
# Non-destructive restore rehearsal:
#   1. Creates a temporary scratch database
#   2. Restores the dump into the scratch DB
#   3. Compares table/row counts between scratch and live
#   4. Drops the scratch DB
#
# Never touches the live database. Returns 0 if the dump restores
# successfully, 1 if the restore fails.
restore_rehearsal_postgres() {
  local stack="$1"
  local compose_cmd="$2"
  local sql_file="$3"

  [ -f "$sql_file" ] || fail "SQL file not found: $sql_file"
  [ -s "$sql_file" ] || fail "Refusing to rehearse: dump is empty: $sql_file"

  if [[ "$sql_file" == *.gz ]]; then
    gzip -t "$sql_file" 2>/dev/null || fail "Refusing to rehearse: gzip integrity check failed for $sql_file"
  fi

  local pg_service="${BACKUP_POSTGRES_SERVICE:-postgres}"
  local pg_user="${POSTGRES_USER:-postgres}"
  local live_db="${POSTGRES_DB:-${pg_user}}"
  local scratch_db="_strut_rehearsal_$$_$(date +%s)"

  log "Restore rehearsal: $sql_file → scratch DB '$scratch_db'"

  # 1. Create scratch database
  log "Creating scratch database..."
  $compose_cmd exec -T "$pg_service" \
    psql -v ON_ERROR_STOP=1 -U "$pg_user" -d postgres \
    -c "CREATE DATABASE \"$scratch_db\";" \
  || { fail "Failed to create scratch database"; return 1; }

  # Ensure cleanup on any exit path
  local _cleanup_done=false
  _rehearsal_cleanup() {
    $_cleanup_done && return 0
    _cleanup_done=true
    $compose_cmd exec -T "$pg_service" \
      psql -U "$pg_user" -d postgres \
      -c "DROP DATABASE IF EXISTS \"$scratch_db\";" >/dev/null 2>&1 || true
  }
  trap _rehearsal_cleanup RETURN

  # 2. Restore into scratch
  log "Restoring dump into scratch database..."
  local restore_rc=0
  if [[ "$sql_file" == *.gz ]]; then
    gunzip -c "$sql_file" | $compose_cmd exec -T "$pg_service" \
      psql -v ON_ERROR_STOP=1 -U "$pg_user" "$scratch_db" >/dev/null 2>&1 || restore_rc=$?
  else
    $compose_cmd exec -T "$pg_service" \
      psql -v ON_ERROR_STOP=1 -U "$pg_user" "$scratch_db" < "$sql_file" >/dev/null 2>&1 || restore_rc=$?
  fi

  if [ "$restore_rc" -ne 0 ]; then
    error "Restore rehearsal FAILED — dump does not apply cleanly"
    _rehearsal_cleanup
    return 1
  fi

  ok "Dump restored successfully into scratch DB"

  # 3. Compare table counts: scratch vs live
  log "Comparing scratch vs live..."
  echo ""
  printf "  %-30s %10s %10s %s\n" "TABLE" "LIVE" "SCRATCH" "STATUS"
  printf "  %-30s %10s %10s %s\n" "─────" "────" "───────" "──────"

  local scratch_tables live_count scratch_count diff_found=false
  scratch_tables=$($compose_cmd exec -T "$pg_service" \
    psql -U "$pg_user" -d "$scratch_db" -tAc \
    "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;" 2>/dev/null) || true

  while IFS= read -r table; do
    [ -n "$table" ] || continue

    live_count=$($compose_cmd exec -T "$pg_service" \
      psql -U "$pg_user" -d "$live_db" -tAc \
      "SELECT count(*) FROM \"$table\";" 2>/dev/null || echo "—")

    scratch_count=$($compose_cmd exec -T "$pg_service" \
      psql -U "$pg_user" -d "$scratch_db" -tAc \
      "SELECT count(*) FROM \"$table\";" 2>/dev/null || echo "—")

    local status="="
    if [ "$live_count" != "$scratch_count" ]; then
      status="≠"
      diff_found=true
    fi

    printf "  %-30s %10s %10s %s\n" "$table" "$live_count" "$scratch_count" "$status"
  done <<< "$scratch_tables"

  echo ""

  # 4. Cleanup (triggered by RETURN trap)
  if $diff_found; then
    warn "Row count differences found between live and backup (expected if data changed since backup)"
  else
    ok "Rehearsal complete — dump restores cleanly, row counts match live"
  fi

  return 0
}

# backup_verify_after <stack> <compose_cmd> <sql_file>
#
# Post-backup verification: immediately rehearses the just-produced dump
# to confirm it restores successfully. Use as:
#   backup_postgres "$stack" "$compose_cmd"
#   backup_verify_after "$stack" "$compose_cmd" "$dump_file"
backup_verify_after() {
  local stack="$1"
  local compose_cmd="$2"
  local sql_file="$3"

  log "Post-backup verification: rehearsing restore of $sql_file"
  if restore_rehearsal_postgres "$stack" "$compose_cmd" "$sql_file"; then
    ok "Backup verified — dump restores successfully"
    return 0
  else
    error "Backup verification FAILED — dump does not restore cleanly"
    return 1
  fi
}
