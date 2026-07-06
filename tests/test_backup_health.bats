#!/usr/bin/env bats
# ==================================================
# tests/test_backup_health.bats — Tests for lib/backup/health.sh
# ==================================================
# Run:  bats tests/test_backup_health.bats
# Covers: get_backup_health_status / get_all_backup_health exit codes
#
# Regression test for OSS-444 / strut#228: get_backup_health_status used to
# `return "$health_score"`, so any healthy service (score > 0) aborted the
# `backup health` command under `set -euo pipefail`.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Source utils with fail() overridden
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }

  # Source backup.sh (it sources submodules including health.sh)
  source "$CLI_ROOT/lib/backup.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/$STACK"
}

# ── get_backup_health_status ─────────────────────────────────────────────────

@test "get_backup_health_status: exits 0 for a healthy service (score > 0)" {
  STACK="test-health-status-$$"
  local metadata_dir="$CLI_ROOT/stacks/$STACK/backups/metadata"
  mkdir -p "$metadata_dir"

  touch "$metadata_dir/postgres-20240101-120000.json"

  run get_backup_health_status "$STACK" "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup Health:"* ]]
}

@test "get_backup_health_status: exits 0 when no metadata exists (score 0)" {
  STACK="test-health-status-empty-$$"
  mkdir -p "$CLI_ROOT/stacks/$STACK/backups/metadata"

  run get_backup_health_status "$STACK" "postgres"
  [ "$status" -eq 0 ]
}

# ── get_all_backup_health ─────────────────────────────────────────────────────

@test "get_all_backup_health: runs to completion across multiple healthy services" {
  STACK="test-health-all-$$"
  local backup_dir="$CLI_ROOT/stacks/$STACK/backups"
  mkdir -p "$backup_dir/metadata"

  touch "$backup_dir/postgres-20240101-120000.sql"
  touch "$backup_dir/metadata/postgres-20240101-120000.json"

  touch "$backup_dir/mysql-20240101-120000.sql"
  touch "$backup_dir/metadata/mysql-20240101-120000.json"

  run get_all_backup_health "$STACK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== PostgreSQL ==="* ]]
  [[ "$output" == *"=== MySQL ==="* ]]
}
