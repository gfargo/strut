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

@test "get_all_backup_health: sees backups placed only in BACKUP_LOCAL_DIR" {
  STACK="test-health-customdir-$$"
  local custom_dir
  custom_dir="$(mktemp -d)"
  mkdir -p "$custom_dir/metadata"

  touch "$custom_dir/postgres-20240101-120000.sql"
  touch "$custom_dir/metadata/postgres-20240101-120000.json"

  export BACKUP_LOCAL_DIR="$custom_dir"
  run get_all_backup_health "$STACK"
  unset BACKUP_LOCAL_DIR
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== PostgreSQL ==="* ]]

  rm -rf "$custom_dir"
}

# ── generate_health_dashboard_data ────────────────────────────────────────────
# Regression test for strut#507: a stack that has never had a backup run has
# no backups/ dir at all yet, so the dashboard-data writes used to crash with
# "No such file or directory" instead of degrading to a structured result.

@test "generate_health_dashboard_data: no backups/ dir yet -> creates it, writes structured 'no history' JSON" {
  STACK="test-health-nodir-$$"
  local backup_dir="$CLI_ROOT/stacks/$STACK/backups"
  [ ! -d "$backup_dir" ]

  run generate_health_dashboard_data "$STACK"
  [ "$status" -eq 0 ]
  [ -f "$backup_dir/health-dashboard.json" ]
  run cat "$backup_dir/health-dashboard.json"
  [[ "$output" == *'"stack": "'"$STACK"'"'* ]]
  [[ "$output" == *'"status": "unknown"'* ]]
  [[ "$output" == *'"message": "No backup history found"'* ]]
  echo "$output" | jq -e 'type == "object"'
}

@test "backup_health_cmd: no backup history -> exits 0 with structured 'no history' JSON, not a crash" {
  STACK="test-health-nodir-cmd-$$"
  local backup_dir="$CLI_ROOT/stacks/$STACK/backups"
  [ ! -d "$backup_dir" ]

  run backup_health_cmd "$STACK" all --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"No such file or directory"* ]]
  [[ "$output" == *'"status": "unknown"'* ]]
  [[ "$output" == *'"message": "No backup history found"'* ]]
}

@test "get_all_backup_health: no backups/ dir yet -> exits 0 with graceful message, not a crash" {
  STACK="test-health-nodir-nonjson-$$"
  local backup_dir="$CLI_ROOT/stacks/$STACK/backups"
  [ ! -d "$backup_dir" ]

  run get_all_backup_health "$STACK"
  [ "$status" -eq 0 ]
  [[ "$output" != *"No such file or directory"* ]]
  [[ "$output" != *"Backup directory not found"* ]]
  [[ "$output" == *"No backup history found"* ]]
}

@test "backup_health_cmd: no backup history, non-JSON -> exits 0, not a crash" {
  STACK="test-health-nodir-cmd-nonjson-$$"
  local backup_dir="$CLI_ROOT/stacks/$STACK/backups"
  [ ! -d "$backup_dir" ]

  run backup_health_cmd "$STACK" all
  [ "$status" -eq 0 ]
  [[ "$output" != *"No such file or directory"* ]]
}

@test "get_backup_health_status: no metadata dir at all -> exits 0 instead of an arithmetic crash" {
  STACK="test-health-status-nodir-$$"
  local backup_dir="$CLI_ROOT/stacks/$STACK/backups"
  [ ! -d "$backup_dir" ]

  run get_backup_health_status "$STACK" "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" != *"syntax error"* ]]
}

@test "get_backup_health_json: no metadata dir at all -> exits 0 with valid JSON, not a crash" {
  STACK="test-health-json-nodir-$$"
  local backup_dir="$CLI_ROOT/stacks/$STACK/backups"
  [ ! -d "$backup_dir" ]

  # Capture stdout only — the soft-fail "No metadata directory found"
  # warnings go to stderr and would otherwise interleave with the JSON.
  local json
  json=$(get_backup_health_json "$STACK" "postgres" 2>/dev/null)
  echo "$json" | jq -e '.health_score == 0'
}
