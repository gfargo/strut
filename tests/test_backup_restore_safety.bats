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

  # fake docker for restore_neo4j_from_targz — no real Docker in CI.
  # FAKE_TAR_OK controls whether the pre-wipe `tar -tzf` integrity check
  # (run inside the fake container) passes.
  docker() {
    echo "$*" >> "$DOCKER_CALL_LOG"
    case "$1" in
      ps)
        echo "test-stack-neo4j-1"
        ;;
      stop|start)
        return 0
        ;;
      inspect)
        if [[ "$*" == *"State.Status"* ]]; then
          echo "exited"
        elif [[ "$*" == *"Mounts"* ]]; then
          echo "fake-data-volume"
        fi
        ;;
      run)
        if [[ "$*" == *"tar -tzf"* ]]; then
          [ "${FAKE_TAR_OK:-1}" = "1" ]
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
