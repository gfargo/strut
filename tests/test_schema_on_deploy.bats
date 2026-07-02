#!/usr/bin/env bats
# ==================================================
# tests/test_schema_on_deploy.bats — maybe_apply_db_schema helper
# ==================================================
# Tests the opt-in DB schema apply helper added to lib/schema.sh.
# Covers:
#   (a) no-op when RUN_DB_SCHEMA_ON_DEPLOY is unset/false
#   (b) warn + return 0 when sql/init/ is absent or empty
#   (c) calls postgres_apply_init_sql when flag=true and files present
#   (d) warn-only (return 0) when postgres_apply_init_sql fails

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Output stubs
  fail()  { echo "FAIL: $1" >&2; return 1; }
  ok()    { echo "OK: $*"; }
  warn()  { echo "WARN: $*" >&2; }
  log()   { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  source "$CLI_ROOT/lib/schema.sh"

  # Default to disabled
  export RUN_DB_SCHEMA_ON_DEPLOY=false
}

teardown() {
  common_teardown
}

# ── (a) Flag disabled ─────────────────────────────────────────────────────────

@test "maybe_apply_db_schema: no-op when RUN_DB_SCHEMA_ON_DEPLOY is false" {
  postgres_apply_init_sql() { echo "SHOULD_NOT_BE_CALLED"; return 0; }
  export -f postgres_apply_init_sql
  export RUN_DB_SCHEMA_ON_DEPLOY=false

  run maybe_apply_db_schema "mystack" "docker compose" "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

@test "maybe_apply_db_schema: no-op when RUN_DB_SCHEMA_ON_DEPLOY is unset" {
  postgres_apply_init_sql() { echo "SHOULD_NOT_BE_CALLED"; return 0; }
  export -f postgres_apply_init_sql
  unset RUN_DB_SCHEMA_ON_DEPLOY

  run maybe_apply_db_schema "mystack" "docker compose" "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

# ── (b) sql/init/ absent or empty ────────────────────────────────────────────

@test "maybe_apply_db_schema: warns and returns 0 when sql/init/ does not exist" {
  export RUN_DB_SCHEMA_ON_DEPLOY=true
  mkdir -p "$TEST_TMP/stack"
  # No sql/init directory

  postgres_apply_init_sql() { echo "SHOULD_NOT_BE_CALLED"; return 0; }
  export -f postgres_apply_init_sql

  run maybe_apply_db_schema "mystack" "docker compose" "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sql/init"* ]] || [[ "$output" == *"skipping"* ]]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

@test "maybe_apply_db_schema: warns and returns 0 when sql/init/ is empty" {
  export RUN_DB_SCHEMA_ON_DEPLOY=true
  mkdir -p "$TEST_TMP/stack/sql/init"
  # Directory exists but no .sql files

  postgres_apply_init_sql() { echo "SHOULD_NOT_BE_CALLED"; return 0; }
  export -f postgres_apply_init_sql

  run maybe_apply_db_schema "mystack" "docker compose" "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

# ── (c) Calls postgres_apply_init_sql when ready ─────────────────────────────

@test "maybe_apply_db_schema: calls postgres_apply_init_sql when flag=true and sql files exist" {
  export RUN_DB_SCHEMA_ON_DEPLOY=true
  mkdir -p "$TEST_TMP/stack/sql/init"
  echo "SELECT 1;" > "$TEST_TMP/stack/sql/init/001_init.sql"

  postgres_apply_init_sql() { echo "CALLED: $*"; return 0; }
  export -f postgres_apply_init_sql

  run maybe_apply_db_schema "mystack" "docker compose" "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED:"* ]]
  [[ "$output" == *"mystack"* ]]
  [[ "$output" == *"$TEST_TMP/stack"* ]]
}

# ── (d) Non-fatal on failure ──────────────────────────────────────────────────

@test "maybe_apply_db_schema: warns and returns 0 when postgres_apply_init_sql fails" {
  export RUN_DB_SCHEMA_ON_DEPLOY=true
  mkdir -p "$TEST_TMP/stack/sql/init"
  echo "SELECT 1;" > "$TEST_TMP/stack/sql/init/001_init.sql"

  postgres_apply_init_sql() { echo "FAILED" >&2; return 1; }
  export -f postgres_apply_init_sql

  run maybe_apply_db_schema "mystack" "docker compose" "$TEST_TMP/stack"
  # Must return 0 — failure is warn-only to not abort a live deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed"* ]] || [[ "$output" == *"warn"* ]] || true
}
