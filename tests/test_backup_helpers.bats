#!/usr/bin/env bats
# ==================================================
# tests/test_backup_helpers.bats — Tests for lib/backup.sh & lib/backup/retention.sh
# ==================================================
# Run:  bats tests/test_backup_helpers.bats
# Covers: _backup_dir, get_backup_list, calculate_backup_age

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  # Source utils with fail() overridden
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }

  # Source backup.sh (it sources submodules including retention.sh)
  source "$CLI_ROOT/lib/backup.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
  unset BACKUP_LOCAL_DIR
}

# ── _backup_dir ───────────────────────────────────────────────────────────────

@test "_backup_dir: returns default path when no config exists" {
  # Use a fake stack with no volume.conf or backup.conf
  unset BACKUP_LOCAL_DIR
  local result
  result=$(_backup_dir "nonexistent-stack")
  [[ "$result" == *"/stacks/nonexistent-stack/backups" ]]
}

@test "_backup_dir: respects BACKUP_LOCAL_DIR env var" {
  export BACKUP_LOCAL_DIR="/custom/backup/path"
  local result
  result=$(_backup_dir "any-stack")
  [ "$result" = "/custom/backup/path" ]
}

@test "_backup_dir: reads from volume.conf and backup.conf" {
  # Create a fake stack with volume.conf + backup.conf
  local stack_dir="$CLI_ROOT/stacks/test-backup-dir-$$"
  mkdir -p "$stack_dir"

  cat > "$stack_dir/volume.conf" <<'EOF'
BACKUP_PATH="/mnt/data/backups"
EOF
  cat > "$stack_dir/backup.conf" <<'EOF'
BACKUP_LOCAL_DIR="${BACKUP_PATH}/daily"
EOF

  unset BACKUP_LOCAL_DIR
  local result
  result=$(_backup_dir "test-backup-dir-$$")
  [ "$result" = "/mnt/data/backups/daily" ]

  # Cleanup
  rm -rf "$stack_dir"
}

# ── get_backup_list ───────────────────────────────────────────────────────────

@test "get_backup_list: lists postgres backups sorted newest first" {
  local stack="test-list-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  # Create test backup files with different timestamps
  touch "$backup_dir/postgres-20240101-120000.sql"
  sleep 0.1
  touch "$backup_dir/postgres-20240102-120000.sql"
  sleep 0.1
  touch "$backup_dir/postgres-20240103-120000.sql"

  run get_backup_list "$stack" "postgres"
  [ "$status" -eq 0 ]
  # Newest should be first
  local first_line
  first_line=$(echo "$output" | head -1)
  [[ "$first_line" == *"postgres-20240103-120000.sql" ]]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: lists neo4j backups with .dump extension" {
  local stack="test-list-neo4j-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  touch "$backup_dir/neo4j-20240101-120000.dump"
  touch "$backup_dir/neo4j-20240102-120000.dump"

  run get_backup_list "$stack" "neo4j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"neo4j-20240101-120000.dump"* ]]
  [[ "$output" == *"neo4j-20240102-120000.dump"* ]]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: lists mysql backups with .sql extension" {
  local stack="test-list-mysql-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  touch "$backup_dir/mysql-20240101-120000.sql"

  run get_backup_list "$stack" "mysql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mysql-20240101-120000.sql"* ]]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: lists sqlite backups with .db extension" {
  local stack="test-list-sqlite-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  touch "$backup_dir/sqlite-20240101-120000.db"

  run get_backup_list "$stack" "sqlite"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sqlite-20240101-120000.db"* ]]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: fails on unknown service" {
  local stack="test-list-unknown-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  run get_backup_list "$stack" "redis"
  [ "$status" -eq 1 ]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: fails when backup directory missing" {
  run get_backup_list "nonexistent-stack-$$" "postgres"
  [ "$status" -eq 1 ]
}

# ── calculate_backup_age ──────────────────────────────────────────────────────

@test "calculate_backup_age: returns 0 for file created today" {
  local test_file="$TEST_TMP/recent-backup.sql"
  touch "$test_file"

  run calculate_backup_age "$test_file"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "calculate_backup_age: fails for missing file" {
  run calculate_backup_age "$TEST_TMP/nonexistent.sql"
  [ "$status" -eq 1 ]
}

@test "calculate_backup_age: returns positive number for old file" {
  local test_file="$TEST_TMP/old-backup.sql"
  touch "$test_file"
  # Set modification time to 5 days ago
  touch -t "$(date -v-5d +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 days ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$test_file"

  run calculate_backup_age "$test_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]  # Allow 1-day rounding tolerance
}
