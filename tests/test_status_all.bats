#!/usr/bin/env bats
# ==================================================
# tests/test_status_all.bats — Tests for strut status-all dashboard
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"

  # Point CLI_ROOT at an isolated tree so tests don't see real stacks
  export REAL_CLI_ROOT="$CLI_ROOT"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CLI_ROOT/stacks"

  source "$REAL_CLI_ROOT/lib/cmd_status_all.sh"

  # Stub resolve_compose_cmd so health probes don't hit real docker
  resolve_compose_cmd() { echo "echo running"; return 0; }
  export -f resolve_compose_cmd
}

teardown() {
  common_teardown
}

# ── Helpers ────────────────────────────────────────────────────────────────────

_make_stack() {
  local name="$1"
  mkdir -p "$CLI_ROOT/stacks/$name"
  touch "$CLI_ROOT/stacks/$name/docker-compose.yml"
}

_add_rollback() {
  local stack="$1"
  local age_secs="${2:-3600}"
  mkdir -p "$CLI_ROOT/stacks/$stack/.rollback"
  local f="$CLI_ROOT/stacks/$stack/.rollback/$(date +%Y%m%d-%H%M%S).json"
  echo '{"timestamp":"test"}' > "$f"
  if [ "$age_secs" -gt 0 ]; then
    # Set mtime in the past
    local ts
    ts=$(($(date +%s) - age_secs))
    touch -t "$(date -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$ts" +%Y%m%d%H%M.%S)" "$f"
  fi
}

_add_backup() {
  local stack="$1"
  local age_secs="${2:-7200}"
  mkdir -p "$CLI_ROOT/stacks/$stack/backups"
  local f="$CLI_ROOT/stacks/$stack/backups/postgres-test.sql"
  echo "backup" > "$f"
  if [ "$age_secs" -gt 0 ]; then
    local ts
    ts=$(($(date +%s) - age_secs))
    touch -t "$(date -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$ts" +%Y%m%d%H%M.%S)" "$f"
  fi
}

# ── Age humanizer ──────────────────────────────────────────────────────────────

@test "_status_humanize_age: seconds" {
  run _status_humanize_age 30
  [ "$output" = "30s ago" ]
}

@test "_status_humanize_age: minutes" {
  run _status_humanize_age 600
  [ "$output" = "10m ago" ]
}

@test "_status_humanize_age: hours" {
  run _status_humanize_age 7200
  [ "$output" = "2h ago" ]
}

@test "_status_humanize_age: days" {
  run _status_humanize_age 172800
  [ "$output" = "2d ago" ]
}

@test "_status_humanize_age: empty input returns dash" {
  run _status_humanize_age ""
  [ "$output" = "-" ]
}

# ── Health detection ──────────────────────────────────────────────────────────

@test "_status_health: no compose file returns unknown" {
  mkdir -p "$CLI_ROOT/stacks/empty"
  run _status_health empty
  [ "$output" = "unknown" ]
}

@test "_status_health: no docker on PATH returns unknown" {
  _make_stack api
  # Force command -v docker to fail
  PATH="" run _status_health api
  [ "$output" = "unknown" ]
}

# ── Drift count ────────────────────────────────────────────────────────────────

@test "_status_drift_count: no metrics file returns dash" {
  _make_stack api
  run _status_drift_count api
  [ "$output" = "-" ]
}

@test "_status_drift_count: reads count from drift.prom" {
  _make_stack api
  mkdir -p "$CLI_ROOT/stacks/api/metrics"
  cat > "$CLI_ROOT/stacks/api/metrics/drift.prom" <<'EOF'
# HELP ch_deploy_drift_files_count drift
# TYPE ch_deploy_drift_files_count gauge
ch_deploy_drift_files_count{stack="api",env="prod"} 3
EOF
  run _status_drift_count api
  [ "$output" = "3" ]
}

@test "_status_drift_count: zero count" {
  _make_stack api
  mkdir -p "$CLI_ROOT/stacks/api/metrics"
  cat > "$CLI_ROOT/stacks/api/metrics/drift.prom" <<'EOF'
ch_deploy_drift_files_count{stack="api",env="prod"} 0
EOF
  run _status_drift_count api
  [ "$output" = "0" ]
}

# ── Last deploy / backup age ─────────────────────────────────────────────────

@test "_status_last_deploy: empty when no rollback dir" {
  _make_stack api
  run _status_last_deploy api
  [ -z "$output" ]
}

@test "_status_last_deploy: returns a timestamp when snapshot exists" {
  _make_stack api
  _add_rollback api 120
  run _status_last_deploy api
  # Non-empty numeric
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "_status_backup_age: empty when no backups dir" {
  _make_stack api
  run _status_backup_age api
  [ -z "$output" ]
}

@test "_status_backup_age: returns a timestamp when backup exists" {
  _make_stack api
  _add_backup api 3600
  run _status_backup_age api
  [[ "$output" =~ ^[0-9]+$ ]]
}

# ── Dashboard command ─────────────────────────────────────────────────────────

@test "cmd_status_all: no stacks directory fails" {
  rm -rf "$CLI_ROOT/stacks"
  run cmd_status_all
  [ "$status" -ne 0 ]
  [[ "$output" == *"No stacks"* ]]
}

@test "cmd_status_all: empty stacks dir — JSON mode returns zero-summary" {
  run cmd_status_all --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"total":0'* ]]
  [[ "$output" == *'"stacks":[]'* ]]
}

@test "cmd_status_all: empty stacks dir — text mode warns and exits 0" {
  run cmd_status_all
  [ "$status" -eq 0 ]
  [[ "$output" == *"No stacks found"* ]]
}

@test "cmd_status_all: text mode renders header and stack row" {
  _make_stack api
  _add_rollback api 7200
  _add_backup api 14400
  run cmd_status_all
  [[ "$output" == *"Dashboard"* ]]
  [[ "$output" == *"Stack"* ]]
  [[ "$output" == *"api"* ]]
  [[ "$output" == *"2h ago"* ]]
  [[ "$output" == *"4h ago"* ]]
}

@test "cmd_status_all: json mode produces valid structure" {
  _make_stack api
  _make_stack worker
  run cmd_status_all --json
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]  # exit 1 if any down
  [[ "$output" == *'"timestamp":'* ]]
  [[ "$output" == *'"stacks":['* ]]
  [[ "$output" == *'"name":"api"'* ]]
  [[ "$output" == *'"name":"worker"'* ]]
  [[ "$output" == *'"summary":'* ]]
  [[ "$output" == *'"total":2'* ]]
}

@test "cmd_status_all: --env propagates to json output" {
  _make_stack api
  run cmd_status_all --env prod --json
  [[ "$output" == *'"env":"prod"'* ]]
}

@test "cmd_status_all: skips 'shared' directory" {
  _make_stack api
  mkdir -p "$CLI_ROOT/stacks/shared"
  run cmd_status_all --json
  [[ "$output" != *'"name":"shared"'* ]]
  [[ "$output" == *'"name":"api"'* ]]
}

@test "cmd_status_all: unknown flag fails" {
  run cmd_status_all --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_status_all: --help prints usage without failing" {
  run cmd_status_all --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"status-all"* ]]
}

@test "cmd_status_all: exit 1 when a stack is down" {
  _make_stack api
  # Force health=down via a stub that echoes down
  _status_health() { echo "down"; }
  export -f _status_health
  run cmd_status_all
  [ "$status" -eq 1 ]
}

@test "cmd_status_all: exit 0 when all stacks unknown (no docker)" {
  _make_stack api
  # Override PATH so docker isn't found
  PATH="" run cmd_status_all
  [ "$status" -eq 0 ]
}
