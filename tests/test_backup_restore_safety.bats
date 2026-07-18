#!/usr/bin/env bats
# ==================================================
# tests/test_backup_restore_safety.bats — Regression tests for OSS-477 / #209
# ==================================================
# Proves: restore paths validate the dump/archive BEFORE any destructive
# action, and report failure (not success) on a partial/corrupt restore.
# Run:  bats tests/test_backup_restore_safety.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"

  # Deliberately do NOT override fail() here (unlike load_utils): these
  # tests assert that restore aborts before any destructive step, which in
  # production relies on fail()'s real `exit 1`. Under `run`, that exit only
  # terminates the command-substitution subshell bats uses to capture
  # $status/$output, so it's safe — and it lets these tests exercise the
  # exact control flow production hits.
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"

  error() { echo "$1" >&2; }
  confirm() { return 0; }

  source "$CLI_ROOT/lib/backup.sh"

  COMPOSE_CALL_LOG="$TEST_TMP/compose_calls.log"
  : > "$COMPOSE_CALL_LOG"

  # fake_compose stands in for `docker compose ...`. It records every
  # invocation so tests can assert whether a destructive/psql step ran at
  # all. FAKE_RESTORE_FAIL controls whether the data-restore psql call
  # (the one without "DROP DATABASE") fails, to simulate ON_ERROR_STOP
  # catching a partial restore.
  fake_compose() {
    echo "$*" >> "$COMPOSE_CALL_LOG"
    if [[ "$*" == *"DROP DATABASE"* ]]; then
      return 0
    fi
    [ "${FAKE_RESTORE_FAIL:-0}" = "1" ] && return 1
    return 0
  }
  export -f fake_compose

  DOCKER_CALL_LOG="$TEST_TMP/docker_calls.log"
  : > "$DOCKER_CALL_LOG"

  # fake docker for restore_neo4j_from_targz / restore_neo4j — no real
  # Docker in CI.
  # FAKE_TAR_OK controls whether the pre-wipe `tar -tzf` integrity check
  # (run inside the fake container) passes (restore_neo4j_from_targz).
  # FAKE_NEO4J_LOAD_OK controls whether the neo4j-admin structural-load
  # check (both the scratch-volume verification in restore_neo4j and its
  # live restore step) reports success.
  docker() {
    echo "$*" >> "$DOCKER_CALL_LOG"
    case "$1" in
      ps)
        # The post-restart "wait for healthy" loop polls `{{.Status}}`;
        # answer it immediately instead of letting the poll run its full
        # ~60s timeout on every happy-path test.
        if [[ "$*" == *"{{.Status}}"* ]]; then
          echo "Up 2 seconds (healthy)"
        else
          echo "test-stack-neo4j-1"
        fi
        ;;
      stop|start)
        return 0
        ;;
      inspect)
        if [[ "$*" == *"State.Status"* ]]; then
          echo "exited"
        elif [[ "$*" == *"Mounts"* ]]; then
          echo "fake-data-volume"
        elif [[ "$*" == *"Config.Image"* ]]; then
          echo "fake-neo4j-image:5.15"
        fi
        ;;
      run)
        if [[ "$*" == *"tar -tzf"* ]]; then
          [ "${FAKE_TAR_OK:-1}" = "1" ]
        elif [[ "$*" == *"neo4j-admin"* && "$*" == *"database load"* ]]; then
          if [ "${FAKE_NEO4J_LOAD_OK:-1}" = "1" ]; then
            echo "Load completed successfully"
            return 0
          else
            return 1
          fi
        else
          return 0
        fi
        ;;
      *)
        return 0
        ;;
    esac
  }
  export -f docker
}

teardown() {
  common_teardown
}

# ── restore_postgres ──────────────────────────────────────────────────────────

@test "restore_postgres: refuses an empty dump without touching the database" {
  local sql_file="$TEST_TMP/empty.sql"
  : > "$sql_file"

  run restore_postgres "test-stack" "fake_compose" "$sql_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty or missing"* ]]
  [ ! -s "$COMPOSE_CALL_LOG" ]
}

@test "restore_postgres: refuses a corrupt gzip dump without touching the database" {
  local sql_file="$TEST_TMP/corrupt.sql.gz"
  echo "not actually gzip content" > "$sql_file"

  run restore_postgres "test-stack" "fake_compose" "$sql_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gzip integrity check failed"* ]]
  [ ! -s "$COMPOSE_CALL_LOG" ]
}

@test "restore_postgres: refuses a missing dump file without touching the database" {
  run restore_postgres "test-stack" "fake_compose" "$TEST_TMP/does-not-exist.sql"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  [ ! -s "$COMPOSE_CALL_LOG" ]
}

@test "restore_postgres: reports failure (not success) when the dump only partially applies" {
  local sql_file="$TEST_TMP/valid.sql"
  echo "SELECT 1;" > "$sql_file"

  FAKE_RESTORE_FAIL=1 run restore_postgres "test-stack" "fake_compose" "$sql_file"
  [ "$status" -ne 0 ]
  [[ "$output" != *"restore complete"* ]]
  [[ "$output" == *"did not fully apply"* ]]
  # Both the drop/recreate and the restore attempt did run in this case —
  # ON_ERROR_STOP is what makes the failed restore report failure instead
  # of a false "complete".
  grep -q "DROP DATABASE" "$COMPOSE_CALL_LOG"
}

@test "restore_postgres: reports success when a valid dump fully applies" {
  local sql_file="$TEST_TMP/valid.sql"
  echo "SELECT 1;" > "$sql_file"

  run restore_postgres "test-stack" "fake_compose" "$sql_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore complete"* ]]
}

@test "restore_postgres: retries the database recreate after a transient connection-teardown race" {
  local sql_file="$TEST_TMP/valid.sql"
  echo "SELECT 1;" > "$sql_file"

  # pg_terminate_backend() signals but doesn't wait for the backend to
  # actually disconnect, so DROP DATABASE can transiently fail with
  # "being accessed by other users" right after. Simulate that: the first
  # two recreate attempts fail, the third (once the connection has
  # settled) succeeds.
  local drop_attempts_file="$TEST_TMP/drop_attempts"
  echo 0 > "$drop_attempts_file"
  fake_compose() {
    echo "$*" >> "$COMPOSE_CALL_LOG"
    if [[ "$*" == *"DROP DATABASE"* ]]; then
      local n
      n=$(($(cat "$drop_attempts_file") + 1))
      echo "$n" > "$drop_attempts_file"
      [ "$n" -ge 3 ] && return 0
      return 1
    fi
    [ "${FAKE_RESTORE_FAIL:-0}" = "1" ] && return 1
    return 0
  }
  export -f fake_compose

  run restore_postgres "test-stack" "fake_compose" "$sql_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore complete"* ]]
  [ "$(cat "$drop_attempts_file")" -eq 3 ]
}

@test "restore_postgres: gives up after repeated database-recreate failures" {
  local sql_file="$TEST_TMP/valid.sql"
  echo "SELECT 1;" > "$sql_file"

  fake_compose() {
    echo "$*" >> "$COMPOSE_CALL_LOG"
    [[ "$*" == *"DROP DATABASE"* ]] && return 1
    [ "${FAKE_RESTORE_FAIL:-0}" = "1" ] && return 1
    return 0
  }
  export -f fake_compose

  run restore_postgres "test-stack" "fake_compose" "$sql_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to recreate database"* ]]
  # Exactly 3 recreate attempts, then gave up — never reached the
  # dump-apply step (which would add a 4th call without "DROP DATABASE").
  [ "$(wc -l < "$COMPOSE_CALL_LOG")" -eq 3 ]
}

# ── restore_neo4j_from_targz ──────────────────────────────────────────────────

@test "restore_neo4j_from_targz: refuses an empty archive without wiping /data" {
  local targz_file="$TEST_TMP/empty.tar.gz"
  : > "$targz_file"

  run restore_neo4j_from_targz "test-stack" "fake_compose" "$targz_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty or missing"* ]]
  ! grep -q "rm -rf /data" "$DOCKER_CALL_LOG"
}

@test "restore_neo4j_from_targz: refuses a corrupt archive without wiping /data" {
  local targz_file="$TEST_TMP/corrupt.tar.gz"
  echo "not a real tar.gz" > "$targz_file"

  FAKE_TAR_OK=0 run restore_neo4j_from_targz "test-stack" "fake_compose" "$targz_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"integrity check"* ]]
  ! grep -q "rm -rf /data" "$DOCKER_CALL_LOG"
}

@test "restore_neo4j_from_targz: refuses a missing archive without wiping /data" {
  run restore_neo4j_from_targz "test-stack" "fake_compose" "$TEST_TMP/does-not-exist.tar.gz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  [ ! -s "$DOCKER_CALL_LOG" ]
}

@test "restore_neo4j_from_targz: wipes and restores /data on a valid archive" {
  local targz_file="$TEST_TMP/valid.tar.gz"
  echo "valid archive contents" > "$targz_file"

  run restore_neo4j_from_targz "test-stack" "fake_compose" "$targz_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore from tar.gz complete"* ]]
  grep -q "rm -rf /data" "$DOCKER_CALL_LOG"
}

# ── restore_neo4j (strut#373) ───────────────────────────────────────────────
# The modern .dump restore path previously validated only `[ -f ]` before
# `--overwrite-destination=true`, so a zero-byte or truncated dump wiped the
# live database and then failed to load — data destroyed, nothing restored.

@test "restore_neo4j: refuses an empty dump without touching the live container" {
  local dump_file="$TEST_TMP/empty.dump"
  : > "$dump_file"

  run restore_neo4j "test-stack" "fake_compose" "$dump_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
  [ ! -s "$DOCKER_CALL_LOG" ]
}

@test "restore_neo4j: refuses a missing dump file without touching the live container" {
  run restore_neo4j "test-stack" "fake_compose" "$TEST_TMP/does-not-exist.dump"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  [ ! -s "$DOCKER_CALL_LOG" ]
}

@test "restore_neo4j: refuses a dump that fails structural validation, without stopping or overwriting the live database" {
  local dump_file="$TEST_TMP/corrupt.dump"
  echo "not actually a neo4j dump" > "$dump_file"

  FAKE_NEO4J_LOAD_OK=0 run restore_neo4j "test-stack" "fake_compose" "$dump_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"structural validation"* ]]

  # The live container must never be touched: no stop, and no live
  # overwrite-destination load against /var/lib/neo4j/import/restore.dump.
  ! grep -q "^stop " "$DOCKER_CALL_LOG"
  ! grep -q "restore.dump /var/lib/neo4j/import/neo4j.dump" "$DOCKER_CALL_LOG"
}

@test "restore_neo4j: validates via a disposable scratch volume, not the live data volume" {
  local dump_file="$TEST_TMP/valid.dump"
  echo "valid dump contents" > "$dump_file"

  run restore_neo4j "test-stack" "fake_compose" "$dump_file"
  [ "$status" -eq 0 ]

  # Verification's scratch volume is created and cleaned up (docker volume
  # create/rm), independently of the live restore's data volume mounts.
  grep -q "^volume create" "$DOCKER_CALL_LOG"
  grep -q "^volume rm" "$DOCKER_CALL_LOG"
}

@test "restore_neo4j: restores the live database once the dump passes structural validation" {
  local dump_file="$TEST_TMP/valid.dump"
  echo "valid dump contents" > "$dump_file"

  run restore_neo4j "test-stack" "fake_compose" "$dump_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore complete"* ]]

  grep -q "^stop " "$DOCKER_CALL_LOG"
  grep -q "restore.dump /var/lib/neo4j/import/neo4j.dump" "$DOCKER_CALL_LOG"
}

# ── restore_mysql (issue #405) ────────────────────────────────────────────────

@test "restore_mysql: refuses an empty dump without touching the database" {
  local f="$TEST_TMP/mysql-empty.sql"
  : > "$f"

  export MYSQL_DATABASE="appdb"
  run restore_mysql "test-stack" "fake_compose" "$f"
  [ "$status" -ne 0 ]
  [ ! -s "$COMPOSE_CALL_LOG" ]
  unset MYSQL_DATABASE
}

@test "restore_mysql: refuses a dump missing the completion marker without touching the database" {
  local f="$TEST_TMP/mysql-truncated.sql"
  echo "INSERT INTO widgets VALUES (1);" > "$f"

  export MYSQL_DATABASE="appdb"
  run restore_mysql "test-stack" "fake_compose" "$f"
  [ "$status" -ne 0 ]
  [ ! -s "$COMPOSE_CALL_LOG" ]
  unset MYSQL_DATABASE
}

@test "restore_mysql: restores a complete dump" {
  local f="$TEST_TMP/mysql-complete.sql"
  cat > "$f" <<'EOF'
INSERT INTO widgets VALUES (1);
-- Dump completed on 2026-01-01 00:00:00
EOF

  export MYSQL_DATABASE="appdb"
  run restore_mysql "test-stack" "fake_compose" "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore complete"* ]]
  unset MYSQL_DATABASE
}

# ── restore_sqlite (issue #405) ───────────────────────────────────────────────

@test "restore_sqlite: refuses an empty backup without touching the live database" {
  local f="$TEST_TMP/sqlite-empty.db"
  : > "$f"
  local live="$TEST_TMP/live.db"
  echo "not empty" > "$live"

  export BACKUP_SQLITE_PATH="$live"
  run restore_sqlite "test-stack" "fake_compose" "$f"
  [ "$status" -ne 0 ]
  [ "$(cat "$live")" = "not empty" ]
  unset BACKUP_SQLITE_PATH
}

@test "restore_sqlite: refuses a corrupt database without touching the live database" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"

  local f="$TEST_TMP/sqlite-corrupt.db"
  sqlite3 "$f" "CREATE TABLE widgets (id INTEGER PRIMARY KEY); INSERT INTO widgets VALUES (1);"
  dd if=/dev/zero of="$f" bs=1 seek=100 count=300 conv=notrunc 2>/dev/null
  local live="$TEST_TMP/live.db"
  echo "not empty" > "$live"

  export BACKUP_SQLITE_PATH="$live"
  run restore_sqlite "test-stack" "fake_compose" "$f"
  [ "$status" -ne 0 ]
  [ "$(cat "$live")" = "not empty" ]
  unset BACKUP_SQLITE_PATH
}

@test "restore_sqlite: restores a valid database and cleans up stale -wal/-shm sidecars" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"

  local f="$TEST_TMP/sqlite-valid.db"
  sqlite3 "$f" "CREATE TABLE widgets (id INTEGER PRIMARY KEY); INSERT INTO widgets VALUES (1);"
  local live="$TEST_TMP/live.db"
  echo "old data" > "$live"
  echo "stale wal" > "$live-wal"
  echo "stale shm" > "$live-shm"

  export BACKUP_SQLITE_PATH="$live"
  run restore_sqlite "test-stack" "fake_compose" "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore complete"* ]]
  [ ! -f "$live-wal" ]
  [ ! -f "$live-shm" ]
  unset BACKUP_SQLITE_PATH
}
