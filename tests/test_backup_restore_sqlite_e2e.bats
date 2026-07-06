#!/usr/bin/env bats
# ==================================================
# tests/test_backup_restore_sqlite_e2e.bats — SQLite backup/restore round trip
# ==================================================
# OSS-399 / strut#253: real round-trip coverage for backup_sqlite/restore_sqlite
# in local-file mode (BACKUP_SQLITE_USE_DOCKER unset/false). Unlike the
# Postgres/MySQL round trips in tests/integration/test_backup_restore_e2e.bats,
# this needs no Docker daemon — backup_sqlite/restore_sqlite operate directly
# on a plain file path — so it lives in tests/ and runs on every PR via the
# standard `bats tests/` job instead of the Docker-gated integration job.
#
# Works whether or not `sqlite3` is installed on the runner: when present, a
# real .db file with a marker row is used (exercising the `sqlite3 .backup`
# path); when absent, falls back to a plain marker file (exercising
# backup_sqlite/restore_sqlite's own documented cp fallback for that case).

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"
  stub_confirm_yes
  source "$CLI_ROOT/lib/backup.sh"

  export CLI_ROOT="$TEST_TMP"
  unset VPS_HOST

  export SQLITE_STACK="sqlite-e2e"
  mkdir -p "$TEST_TMP/stacks/$SQLITE_STACK"
  export SQLITE_DB_PATH="$TEST_TMP/app.db"
  export BACKUP_SQLITE_PATH="$SQLITE_DB_PATH"
}

teardown() {
  common_teardown
}

# _write_marker <path> <value> — real sqlite3 row when available, else a
# plain marker file (matches backup_sqlite/restore_sqlite's own fallback).
_write_marker() {
  local path="$1" value="$2"
  if command -v sqlite3 &>/dev/null; then
    rm -f "$path"
    sqlite3 "$path" "CREATE TABLE marker (val TEXT); INSERT INTO marker VALUES ('$value');"
  else
    echo "$value" > "$path"
  fi
}

_read_marker() {
  local path="$1"
  if command -v sqlite3 &>/dev/null; then
    sqlite3 "$path" "SELECT val FROM marker;"
  else
    cat "$path"
  fi
}

@test "sqlite backup/restore: marker row survives a full backup -> destroy -> restore cycle" {
  _write_marker "$SQLITE_DB_PATH" "backup-restore-marker-e2e"

  run backup_sqlite "$SQLITE_STACK" ""
  [ "$status" -eq 0 ]

  local backup_file
  backup_file=$(ls -t "$TEST_TMP/stacks/$SQLITE_STACK/backups"/sqlite-*.db 2>/dev/null | head -1)
  [ -n "$backup_file" ]
  [ -s "$backup_file" ]

  # Destroy the live database — simulates the disaster restore fixes.
  _write_marker "$SQLITE_DB_PATH" "corrupted-should-not-survive"

  run restore_sqlite "$SQLITE_STACK" "" "$backup_file"
  [ "$status" -eq 0 ]

  run _read_marker "$SQLITE_DB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-restore-marker-e2e"* ]]
  [[ "$output" != *"corrupted-should-not-survive"* ]]
}

@test "sqlite backup/restore: restore is a no-op when confirm is declined" {
  stub_confirm_no
  _write_marker "$SQLITE_DB_PATH" "original-marker"

  run backup_sqlite "$SQLITE_STACK" ""
  [ "$status" -eq 0 ]
  local backup_file
  backup_file=$(ls -t "$TEST_TMP/stacks/$SQLITE_STACK/backups"/sqlite-*.db 2>/dev/null | head -1)
  [ -n "$backup_file" ]

  _write_marker "$SQLITE_DB_PATH" "changed-after-backup"

  run restore_sqlite "$SQLITE_STACK" "" "$backup_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cancelled"* ]]

  run _read_marker "$SQLITE_DB_PATH"
  [[ "$output" == *"changed-after-backup"* ]]
}
