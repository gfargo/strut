#!/usr/bin/env bats
# ==================================================
# tests/test_volumes.bats — Tests for lib/volumes.sh helpers
# ==================================================
# Run:  bats tests/test_volumes.bats
# Covers: export_volume_paths, verify_volume_config, init_volume_directories

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLI_ROOT
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_volumes() {
  source "$CLI_ROOT/lib/utils.sh"
  # Stub log functions used in volumes.sh (not defined in utils.sh)
  log_info()    { echo "[info] $1"; }
  log_success() { echo "[ok] $1"; }
  log_warn()    { echo "[warn] $1"; }
  log_error()   { echo "[error] $1" >&2; }
  source "$CLI_ROOT/lib/volumes.sh"
  fail() { echo "$1" >&2; return 1; }
}

# ── export_volume_paths ───────────────────────────────────────────────────────

@test "export_volume_paths: exports vars from volume.conf" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/volume.conf" <<'EOF'
NEO4J_DATA_PATH=/mnt/data/neo4j
POSTGRES_DATA_PATH=/mnt/data/postgres
BACKUP_PATH=/mnt/data/backups
LOG_PATH=/mnt/data/logs
GDRIVE_TRANSCRIPTS_PATH=/mnt/data/gdrive
DATA_VOLUME_MOUNT=/mnt/data
EOF

  export_volume_paths "$TEST_TMP/stack"
  [ "$NEO4J_DATA_PATH" = "/mnt/data/neo4j" ]
  [ "$POSTGRES_DATA_PATH" = "/mnt/data/postgres" ]
  [ "$BACKUP_PATH" = "/mnt/data/backups" ]
  [ "$LOG_PATH" = "/mnt/data/logs" ]
  [ "$GDRIVE_TRANSCRIPTS_PATH" = "/mnt/data/gdrive" ]
  [ "$DATA_VOLUME_MOUNT" = "/mnt/data" ]
}

@test "export_volume_paths: no-op when volume.conf missing" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  # No volume.conf — should not fail
  export_volume_paths "$TEST_TMP/stack"
}

@test "export_volume_paths: works with real knowledge-graph stack" {
  _load_volumes
  local kg_dir="$CLI_ROOT/stacks/knowledge-graph"
  if [ -f "$kg_dir/volume.conf" ]; then
    export_volume_paths "$kg_dir"
    # Should have exported something (at least DATA_VOLUME_MOUNT)
    [ -n "${DATA_VOLUME_MOUNT:-}" ] || [ -n "${NEO4J_DATA_PATH:-}" ]
  else
    skip "knowledge-graph/volume.conf not found"
  fi
}

# ── export_volume_paths: dynamic/arbitrary variables ──────────────────────────

@test "export_volume_paths: exports arbitrary *_DATA_PATH variables" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/volume.conf" <<'EOF'
REDIS_DATA_PATH=/mnt/data/redis
ELASTIC_DATA_PATH=/mnt/data/elastic
MONGO_DATA_PATH=/mnt/data/mongo
EOF

  export_volume_paths "$TEST_TMP/stack"
  [ "$REDIS_DATA_PATH" = "/mnt/data/redis" ]
  [ "$ELASTIC_DATA_PATH" = "/mnt/data/elastic" ]
  [ "$MONGO_DATA_PATH" = "/mnt/data/mongo" ]
}

@test "export_volume_paths: exports arbitrary *_PATH variables" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/volume.conf" <<'EOF'
CACHE_PATH=/mnt/data/cache
UPLOAD_PATH=/mnt/data/uploads
EOF

  export_volume_paths "$TEST_TMP/stack"
  [ "$CACHE_PATH" = "/mnt/data/cache" ]
  [ "$UPLOAD_PATH" = "/mnt/data/uploads" ]
}

@test "export_volume_paths: exports arbitrary DATA_VOLUME_* variables" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/volume.conf" <<'EOF'
DATA_VOLUME_MOUNT=/mnt/data
DATA_VOLUME_DEVICE=/dev/sdb1
DATA_VOLUME_SIZE=100G
DATA_VOLUME_CUSTOM=foobar
EOF

  export_volume_paths "$TEST_TMP/stack"
  [ "$DATA_VOLUME_MOUNT" = "/mnt/data" ]
  [ "$DATA_VOLUME_DEVICE" = "/dev/sdb1" ]
  [ "$DATA_VOLUME_SIZE" = "100G" ]
  [ "$DATA_VOLUME_CUSTOM" = "foobar" ]
}

# ── verify_volume_config: dynamic display ─────────────────────────────────────

@test "verify_volume_config: displays all path variables dynamically" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/volume.conf" <<'EOF'
DATA_VOLUME_MOUNT=/mnt/data
REDIS_DATA_PATH=/mnt/data/redis
SEARCH_DATA_PATH=/mnt/data/search
CACHE_PATH=/mnt/data/cache
EOF

  run verify_volume_config "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  # Should contain the variable names in output
  [[ "$output" == *"REDIS_DATA_PATH"* ]]
  [[ "$output" == *"SEARCH_DATA_PATH"* ]]
  [[ "$output" == *"CACHE_PATH"* ]]
  # Should contain the values
  [[ "$output" == *"/mnt/data/redis"* ]]
  [[ "$output" == *"/mnt/data/search"* ]]
  [[ "$output" == *"/mnt/data/cache"* ]]
}

@test "verify_volume_config: does not contain hardcoded service names" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/volume.conf" <<'EOF'
DATA_VOLUME_MOUNT=/mnt/data
CUSTOM_DATA_PATH=/mnt/data/custom
EOF

  run verify_volume_config "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  # Must NOT contain hardcoded service names
  [[ "$output" != *"Neo4j:"* ]]
  [[ "$output" != *"Postgres:"* ]]
  [[ "$output" != *"GDrive Transcripts:"* ]]
}

@test "verify_volume_config: returns 1 when volume.conf missing" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  run verify_volume_config "$TEST_TMP/stack"
  [ "$status" -eq 1 ]
}


# ── init_volume_directories: dynamic directory creation ───────────────────────

@test "init_volume_directories: creates directories for arbitrary path variables" {
  _load_volumes
  local mount="$TEST_TMP/mnt/data"
  mkdir -p "$mount"

  # Stub mountpoint to succeed for our test mount
  mountpoint() { [[ "$2" == "$mount" ]] && return 0 || command mountpoint "$@"; }

  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/volume.conf" <<EOF
DATA_VOLUME_MOUNT=$mount
DB_DATA_PATH=$mount/db
SEARCH_DATA_PATH=$mount/search
CACHE_PATH=$mount/cache
EOF

  init_volume_directories "$TEST_TMP/stack"

  [ -d "$mount/db" ]
  [ -d "$mount/search" ]
  [ -d "$mount/cache" ]
}

@test "init_volume_directories: applies VOLUME_OWNERS mappings" {
  _load_volumes
  local mount="$TEST_TMP/mnt/data"
  mkdir -p "$mount"

  mountpoint() { [[ "$2" == "$mount" ]] && return 0 || command mountpoint "$@"; }

  # Track chown calls instead of actually running chown
  local chown_log="$TEST_TMP/chown.log"
  chown() { echo "chown $*" >> "$chown_log"; }

  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/volume.conf" <<EOF
DATA_VOLUME_MOUNT=$mount
DB_DATA_PATH=$mount/db
SEARCH_DATA_PATH=$mount/search
VOLUME_OWNERS="DB_DATA_PATH=999:999 SEARCH_DATA_PATH=1000:1000"
EOF

  init_volume_directories "$TEST_TMP/stack"

  # Directories should be created
  [ -d "$mount/db" ]
  [ -d "$mount/search" ]

  # chown should have been called with correct uid:gid
  [ -f "$chown_log" ]
  grep -q "999:999 $mount/db" "$chown_log"
  grep -q "1000:1000 $mount/search" "$chown_log"
}

@test "init_volume_directories: returns 1 when volume.conf missing" {
  _load_volumes
  mkdir -p "$TEST_TMP/stack"
  run init_volume_directories "$TEST_TMP/stack"
  [ "$status" -eq 1 ]
}

# ── Static analysis: no hardcoded service names or UIDs ───────────────────────

@test "volumes.sh: no hardcoded NEO4J_DATA_PATH in export/init logic" {
  # Grep for hardcoded NEO4J_DATA_PATH outside of comments
  local result
  result=$(grep -n 'NEO4J_DATA_PATH' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}

@test "volumes.sh: no hardcoded POSTGRES_DATA_PATH in export/init logic" {
  local result
  result=$(grep -n 'POSTGRES_DATA_PATH' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}

@test "volumes.sh: no hardcoded GDRIVE_TRANSCRIPTS_PATH in export/init logic" {
  local result
  result=$(grep -n 'GDRIVE_TRANSCRIPTS_PATH' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}

@test "volumes.sh: no hardcoded UID 7474 (Neo4j)" {
  local result
  result=$(grep -n '7474' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}

@test "volumes.sh: no hardcoded UID 999 (Postgres)" {
  local result
  result=$(grep -n '999' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}

@test "volumes.sh: no hardcoded UID 1000 (GDrive)" {
  # Check for standalone 1000 used as a UID, not in comments
  local result
  result=$(grep -n '\b1000\b' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}

@test "volumes.sh: no hardcoded service name 'Neo4j' in output" {
  local result
  result=$(grep -n 'Neo4j' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}

@test "volumes.sh: no hardcoded service name 'Postgres' in output" {
  local result
  result=$(grep -n 'Postgres' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}

@test "volumes.sh: no hardcoded 'GDrive Transcripts' in output" {
  local result
  result=$(grep -n 'GDrive' "$CLI_ROOT/lib/volumes.sh" | grep -v '^\s*#' || true)
  [ -z "$result" ]
}
