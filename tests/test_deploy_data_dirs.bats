#!/usr/bin/env bats
# ==================================================
# tests/test_deploy_data_dirs.bats — STACK_DATA_DIRS logic in deploy_stack
# ==================================================
# Covers OSS-930 / strut#417:
#   1. No hardcoded data/postgres data/redis data/gdrive default
#   2. STACK_DATA_DIRS="" (empty) must suppress all directory creation
#   3. Derive dirs from DB_* flags in services.conf when STACK_DATA_DIRS unset
#   4. Fall back to "data" when no DB_* flags and STACK_DATA_DIRS unset
#
# Exercises the real _deploy_resolve_data_dirs function from lib/deploy.sh
# directly — not a copy of its logic — so these tests can't silently drift
# from the production code path the way a duplicated-logic helper could.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/deploy.sh"

  # Build a minimal stack dir for each test (some tests use it directly;
  # _deploy_resolve_data_dirs itself is stack-dir-agnostic — it only echoes
  # relative paths — but keeping it around lets tests also assert mkdir -p
  # behavior end-to-end where useful).
  export STACK_DIR="$TEST_TMP/stacks/mystack"
  mkdir -p "$STACK_DIR"

  # Unset STACK_DATA_DIRS and all DB_* flags so each test starts clean
  unset STACK_DATA_DIRS
  unset DB_POSTGRES DB_REDIS DB_NEO4J DB_MYSQL
}

teardown() {
  common_teardown
}

# _apply_data_dirs <stack_dir>
# Runs the real resolver and actually creates the directories, mirroring
# what deploy_stack's "[4/5] Creating data directories..." step does.
_apply_data_dirs() {
  local stack_dir="$1"
  local data_dirs
  data_dirs=$(_deploy_resolve_data_dirs)
  for dir in $data_dirs; do
    mkdir -p "$stack_dir/$dir"
  done
}

# ── 1. Empty opt-out: STACK_DATA_DIRS="" must skip all directory creation ─────

@test "deploy data dirs: STACK_DATA_DIRS='' suppresses all directory creation" {
  export STACK_DATA_DIRS=""
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  _apply_data_dirs "$STACK_DIR"
  # data/ must NOT be created
  [ ! -d "$STACK_DIR/data" ]
  # postgres/redis must NOT be created either
  [ ! -d "$STACK_DIR/data/postgres" ]
  [ ! -d "$STACK_DIR/data/redis" ]
}

# ── 2. Explicit override: STACK_DATA_DIRS=custom creates only those dirs ──────

@test "deploy data dirs: STACK_DATA_DIRS with custom path creates only that path" {
  export STACK_DATA_DIRS="volumes/app"
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "volumes/app" ]

  _apply_data_dirs "$STACK_DIR"
  [ -d "$STACK_DIR/volumes/app" ]
  [ ! -d "$STACK_DIR/data" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
}

@test "deploy data dirs: STACK_DATA_DIRS with multiple paths creates all of them" {
  export STACK_DATA_DIRS="vol/a vol/b"
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "vol/a vol/b" ]

  _apply_data_dirs "$STACK_DIR"
  [ -d "$STACK_DIR/vol/a" ]
  [ -d "$STACK_DIR/vol/b" ]
  [ ! -d "$STACK_DIR/data" ]
}

# ── 3. DB_* derivation when STACK_DATA_DIRS is unset ─────────────────────────

@test "deploy data dirs: DB_POSTGRES=true creates data/postgres (no gdrive or redis)" {
  export DB_POSTGRES=true
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "data/postgres" ]

  _apply_data_dirs "$STACK_DIR"
  [ -d "$STACK_DIR/data/postgres" ]
  [ ! -d "$STACK_DIR/data/redis" ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

@test "deploy data dirs: DB_REDIS=true creates data/redis only" {
  export DB_REDIS=true
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "data/redis" ]

  _apply_data_dirs "$STACK_DIR"
  [ -d "$STACK_DIR/data/redis" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

@test "deploy data dirs: DB_NEO4J=true creates data/neo4j only" {
  export DB_NEO4J=true
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "data/neo4j" ]

  _apply_data_dirs "$STACK_DIR"
  [ -d "$STACK_DIR/data/neo4j" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
}

@test "deploy data dirs: DB_MYSQL=true creates data/mysql only" {
  export DB_MYSQL=true
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "data/mysql" ]

  _apply_data_dirs "$STACK_DIR"
  [ -d "$STACK_DIR/data/mysql" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
}

@test "deploy data dirs: multiple DB_* flags create all corresponding dirs, no leading/double spaces" {
  export DB_POSTGRES=true
  export DB_REDIS=true
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "data/postgres data/redis" ]

  _apply_data_dirs "$STACK_DIR"
  [ -d "$STACK_DIR/data/postgres" ]
  [ -d "$STACK_DIR/data/redis" ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

# ── 4. No DB_* flags → fall back to "data" ───────────────────────────────────

@test "deploy data dirs: no DB_* flags and STACK_DATA_DIRS unset creates only data/" {
  # All DB_* flags already unset in setup()
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "data" ]

  _apply_data_dirs "$STACK_DIR"
  [ -d "$STACK_DIR/data" ]
  [ ! -d "$STACK_DIR/data/postgres" ]
  [ ! -d "$STACK_DIR/data/redis" ]
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

# ── 5. No hardcoded gdrive default in any path ───────────────────────────────

@test "deploy data dirs: gdrive directory is never created by default (unset STACK_DATA_DIRS)" {
  # Simulate a plain stack with all DB_* flags unset
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [[ "$output" != *"gdrive"* ]]

  _apply_data_dirs "$STACK_DIR"
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

@test "deploy data dirs: gdrive directory not created when only DB_POSTGRES is set" {
  export DB_POSTGRES=true
  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [[ "$output" != *"gdrive"* ]]

  _apply_data_dirs "$STACK_DIR"
  [ ! -d "$STACK_DIR/data/gdrive" ]
}

# ── services.conf → _deploy_resolve_data_dirs wiring ─────────────────────────
# load_services_conf is how STACK_DATA_DIRS actually reaches deploy_stack in
# production (via safe_source_config, not a manually-exported env var like
# the tests above) — worth proving that path specifically, since it's the
# one an operator's services.conf file actually exercises.

@test "services.conf: STACK_DATA_DIRS= (empty) loaded via load_services_conf suppresses all directory creation" {
  local stack_dir="$TEST_TMP/stacks/confstack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
STACK_DATA_DIRS=
EOF

  unset STACK_DATA_DIRS
  load_services_conf "$stack_dir"

  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "services.conf: STACK_DATA_DIRS=volumes/app loaded via load_services_conf creates only that path" {
  local stack_dir="$TEST_TMP/stacks/confstack2"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
STACK_DATA_DIRS=volumes/app
EOF

  unset STACK_DATA_DIRS
  load_services_conf "$stack_dir"

  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "volumes/app" ]
}

@test "services.conf: DB_POSTGRES=true loaded via load_services_conf derives data/postgres" {
  local stack_dir="$TEST_TMP/stacks/confstack3"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
DB_POSTGRES=true
EOF

  unset STACK_DATA_DIRS DB_POSTGRES
  load_services_conf "$stack_dir"

  run _deploy_resolve_data_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "data/postgres" ]
}
