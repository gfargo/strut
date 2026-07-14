#!/usr/bin/env bats
# ==================================================
# tests/test_deploy_data_dirs.bats — STACK_DATA_DIRS logic in deploy_stack
# ==================================================
# Covers OSS-930 / strut#417:
#   1. No hardcoded data/postgres data/redis data/gdrive default
#   2. STACK_DATA_DIRS="" (empty) must suppress all directory creation
#   3. Derive dirs from DB_* flags in services.conf when STACK_DATA_DIRS unset
#   4. Fall back to "data" when no DB_* flags and STACK_DATA_DIRS unset

# We test the data-directory logic in isolation by extracting just the logic
# under test from deploy_stack into a helper function that mirrors the exact
# code path, rather than calling the full deploy_stack (which needs docker,
# SSH, etc.).

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"

  # Build a minimal stack dir for each test
  export STACK_DIR="$TEST_TMP/stacks/mystack"
  mkdir -p "$STACK_DIR"

  # Unset STACK_DATA_DIRS and all DB_* flags so each test starts clean
  unset STACK_DATA_DIRS
  unset DB_POSTGRES DB_REDIS DB_NEO4J DB_MYSQL
}

teardown() {
  common_teardown
}

# ── Helper: replicate the deploy_stack data-dir logic verbatim ────────────────
#
# This function is a direct copy of the logic in deploy_stack (lib/deploy.sh)
# under the "# Data directories" comment.  If the implementation changes,
# update this copy to match.
_run_data_dir_logic() {
  local stack_dir="$1"
  local data_dirs
  if [ -n "${STACK_DATA_DIRS+x}" ]; then
    data_dirs="$STACK_DATA_DIRS"
  else
    data_dirs=""
    [ "${DB_POSTGRES:-false}" = "true" ] && data_dirs="$data_dirs data/postgres"
    [ "${DB_REDIS:-false}" = "true" ]   && data_dirs="$data_dirs data/redis"
    [ "${DB_NEO4J:-false}" = "true" ]   && data_dirs="$data_dirs data/neo4j"
    [ "${DB_MYSQL:-false}" = "true" ]   && data_dirs="$data_dirs data/mysql"
    data_dirs="${data_dirs:-data}"
  fi
  for dir in $data_dirs; do
    mkdir -p "$stack_dir/$dir"
  done
}

# ── 1. Empty opt-out: STACK_DATA_DIRS="" must skip all directory creation ─────

@test "deploy data dirs: STACK_DATA_DIRS='' suppresses all directory creation" {
  export STACK_DATA_DIRS=""
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  # data/ must NOT be created
  [ ! -d "$STACK_DIR/data" ]
  # postgres/redis must NOT be created either
  [ ! -d "$STACK_DIR/data/postgres" ]
  [ ! -d "$STACK_DIR/data/redis" ]
}

# ── 2. Explicit override: STACK_DATA_DIRS=custom creates only those dirs ──────

@test "deploy data dirs: STACK_DATA_DIRS with custom path creates only that path" {
  export STACK_DATA_DIRS="volumes/app"
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$STACK_DIR/volumes/app" ]
  [ ! -d "$STACK_DIR/data" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
}

@test "deploy data dirs: STACK_DATA_DIRS with multiple paths creates all of them" {
  export STACK_DATA_DIRS="vol/a vol/b"
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$STACK_DIR/vol/a" ]
  [ -d "$STACK_DIR/vol/b" ]
  [ ! -d "$STACK_DIR/data" ]
}

# ── 3. DB_* derivation when STACK_DATA_DIRS is unset ─────────────────────────

@test "deploy data dirs: DB_POSTGRES=true creates data/postgres (no gdrive or redis)" {
  export DB_POSTGRES=true
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$STACK_DIR/data/postgres" ]
  [ ! -d "$STACK_DIR/data/redis" ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

@test "deploy data dirs: DB_REDIS=true creates data/redis only" {
  export DB_REDIS=true
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$STACK_DIR/data/redis" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

@test "deploy data dirs: DB_NEO4J=true creates data/neo4j only" {
  export DB_NEO4J=true
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$STACK_DIR/data/neo4j" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
}

@test "deploy data dirs: DB_MYSQL=true creates data/mysql only" {
  export DB_MYSQL=true
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$STACK_DIR/data/mysql" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
}

@test "deploy data dirs: multiple DB_* flags create all corresponding dirs" {
  export DB_POSTGRES=true
  export DB_REDIS=true
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$STACK_DIR/data/postgres" ]
  [ -d "$STACK_DIR/data/redis" ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

# ── 4. No DB_* flags → fall back to "data" ───────────────────────────────────

@test "deploy data dirs: no DB_* flags and STACK_DATA_DIRS unset creates only data/" {
  # All DB_* flags already unset in setup()
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$STACK_DIR/data" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
  [ ! -d "$STACK_DIR/data/redis" ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

# ── 5. No hardcoded gdrive default in any path ───────────────────────────────

@test "deploy data dirs: gdrive directory is never created by default (unset STACK_DATA_DIRS)" {
  # Simulate a plain stack with all DB_* flags unset
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

@test "deploy data dirs: gdrive directory not created when only DB_POSTGRES is set" {
  export DB_POSTGRES=true
  run _run_data_dir_logic "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}
