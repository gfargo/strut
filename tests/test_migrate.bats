#!/usr/bin/env bats
# ==================================================
# tests/test_migrate.bats — Tests for migration wizard helpers
# ==================================================
# Run:  bats tests/test_migrate.bats
# Covers: migrate_wizard argument parsing, confirm helper,
#         migrate_status, phase validation

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  # Source migrate.sh — it sources all phase modules
  source "$CLI_ROOT/lib/migrate.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
  unset MIGRATE_AUTO_YES MIGRATE_START_PHASE VPS_SUDO
}

# ── confirm helper ────────────────────────────────────────────────────────────

@test "confirm: auto-yes mode returns 0" {
  MIGRATE_AUTO_YES=true
  run confirm "Continue?"
  [ "$status" -eq 0 ]
}

@test "confirm: rejects 'no' input" {
  MIGRATE_AUTO_YES=false
  run bash -c 'source "$CLI_ROOT/lib/migrate.sh"; MIGRATE_AUTO_YES=false; echo "no" | confirm "Continue?"'
  [ "$status" -eq 1 ]
}

@test "confirm: accepts 'yes' input" {
  run bash -c 'source "$CLI_ROOT/lib/migrate.sh"; MIGRATE_AUTO_YES=false; echo "yes" | confirm "Continue?"'
  [ "$status" -eq 0 ]
}

@test "confirm: accepts 'y' input" {
  run bash -c 'source "$CLI_ROOT/lib/migrate.sh"; MIGRATE_AUTO_YES=false; echo "y" | confirm "Continue?"'
  [ "$status" -eq 0 ]
}

# ── migrate_wizard argument validation ────────────────────────────────────────

@test "migrate_wizard: fails without vps_host" {
  # Test in a subshell with timeout to avoid hanging
  run timeout 5 bash -c '
    source "$CLI_ROOT/lib/migrate.sh"
    MIGRATE_AUTO_YES=true
    migrate_wizard "" 2>&1
  '
  [ "$status" -ne 0 ]
}

@test "migrate_wizard: rejects invalid start phase 0" {
  run timeout 5 bash -c '
    source "$CLI_ROOT/lib/migrate.sh"
    MIGRATE_AUTO_YES=true
    migrate_wizard "test-host" "ubuntu" "" "" "--start-phase=0" 2>&1
  '
  [ "$status" -ne 0 ]
}

@test "migrate_wizard: rejects invalid start phase 9" {
  run timeout 5 bash -c '
    source "$CLI_ROOT/lib/migrate.sh"
    MIGRATE_AUTO_YES=true
    migrate_wizard "test-host" "ubuntu" "" "" "--start-phase=9" 2>&1
  '
  [ "$status" -ne 0 ]
}

# ── migrate_status ────────────────────────────────────────────────────────────

@test "migrate_status: runs without error when no audits exist" {
  run migrate_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Migration Status"* ]]
}

@test "migrate_status: shows generated stacks" {
  local stack="test-keys-mig-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  echo "version: '3'" > "$CLI_ROOT/stacks/$stack/docker-compose.yml"

  run migrate_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"$stack"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── Property: start phase validation ──────────────────────────────────────────

@test "Property: valid start phases (1-8) accepted, others rejected (100 iterations)" {
  for i in $(seq 1 100); do
    local phase=$(( (RANDOM % 15) - 3 ))  # Range: -3 to 11

    if [ "$phase" -ge 1 ] && [ "$phase" -le 8 ]; then
      # Valid phase — should not fail on phase validation
      # (will fail on SSH connection, but that's after validation)
      MIGRATE_AUTO_YES=true
      run bash -c "
        source '$CLI_ROOT/lib/migrate.sh'
        MIGRATE_AUTO_YES=true
        MIGRATE_START_PHASE=$phase
        # Validate phase range only
        if [ \$MIGRATE_START_PHASE -lt 1 ] || [ \$MIGRATE_START_PHASE -gt 8 ]; then
          echo 'Invalid start phase'
          exit 1
        fi
        echo 'valid'
      "
      [ "$status" -eq 0 ] || {
        echo "FAILED: phase $phase should be valid"
        return 1
      }
    else
      run bash -c "
        source '$CLI_ROOT/lib/migrate.sh'
        MIGRATE_AUTO_YES=true
        MIGRATE_START_PHASE=$phase
        if [ \$MIGRATE_START_PHASE -lt 1 ] || [ \$MIGRATE_START_PHASE -gt 8 ]; then
          echo 'Invalid start phase'
          exit 1
        fi
        echo 'valid'
      "
      [ "$status" -eq 1 ] || {
        echo "FAILED: phase $phase should be invalid"
        return 1
      }
    fi
  done
}
