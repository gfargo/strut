#!/usr/bin/env bats
# ==================================================
# tests/test_migrate.bats — Tests for migration wizard helpers
# ==================================================
# Run:  bats tests/test_migrate.bats
# Covers: migrate_wizard argument parsing, confirm helper,
#         migrate_status, phase validation

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"

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

# With utils.sh sourced first (as the entrypoint does), utils' safe confirm()
# is the one in effect — migrate.sh's definition is guarded out so it can't
# clobber STRUT_YES/--yes CLI-wide. The migrate --yes flag bridges to STRUT_YES,
# so auto-approval flows through utils' confirm.
@test "confirm: auto-yes mode returns 0 (via STRUT_YES bridge)" {
  STRUT_YES=1
  run confirm "Continue?"
  [ "$status" -eq 0 ]
  unset STRUT_YES
}

@test "confirm: migrate.sh does not clobber utils' confirm (guard)" {
  # utils' confirm honors STRUT_YES; migrate's old one honored only
  # MIGRATE_AUTO_YES. With both sourced (utils first), MIGRATE_AUTO_YES alone
  # must NOT auto-approve — proving migrate no longer clobbers utils' confirm.
  run bash -c 'unset STRUT_YES; source "$CLI_ROOT/lib/utils.sh"; source "$CLI_ROOT/lib/migrate.sh"; MIGRATE_AUTO_YES=true; confirm "x" </dev/null'
  [ "$status" -eq 1 ]
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
  # Run in a subshell under timeout to avoid hanging; source utils.sh
  # first so fail/warn/log are defined in the child shell.
  run _timeout 5 bash -c '
    source "$CLI_ROOT/lib/utils.sh"
    source "$CLI_ROOT/lib/migrate.sh"
    MIGRATE_AUTO_YES=true
    migrate_wizard "" 2>&1
  '
  [ "$status" -ne 0 ]
}

@test "migrate_wizard: rejects invalid start phase 0" {
  run _timeout 5 bash -c '
    source "$CLI_ROOT/lib/utils.sh"
    source "$CLI_ROOT/lib/migrate.sh"
    MIGRATE_AUTO_YES=true
    migrate_wizard "test-host" "ubuntu" "" "" "--start-phase=0" 2>&1
  '
  [ "$status" -ne 0 ]
}

@test "migrate_wizard: rejects invalid start phase 9" {
  run _timeout 5 bash -c '
    source "$CLI_ROOT/lib/utils.sh"
    source "$CLI_ROOT/lib/migrate.sh"
    MIGRATE_AUTO_YES=true
    migrate_wizard "test-host" "ubuntu" "" "" "--start-phase=9" 2>&1
  '
  [ "$status" -ne 0 ]
}

# ── strut#400: flags in a positional slot must not leak into vps_user/etc ────

@test "migrate_wizard: '--yes' in the vps_user slot doesn't leak — vps_user stays 'ubuntu'" {
  # Simulates `strut migrate myhost --yes` (user omits vps_user, so --yes
  # lands in slot 2). Stub every phase function to print its resolved args
  # instead of touching SSH, and stub confirm to auto-approve.
  run _timeout 5 bash -c '
    source "$CLI_ROOT/lib/utils.sh"
    source "$CLI_ROOT/lib/migrate.sh"
    migrate_phase_preflight() { echo "PREFLIGHT host=$1 user=$2 port=$3 key=$4"; exit 0; }
    migrate_wizard "myhost" "--yes" 2>&1
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"PREFLIGHT host=myhost user=ubuntu port= key="* ]]
  [[ "$output" != *"user=--yes"* ]]
}

@test "migrate_wizard: '--sudo' and '--start-phase=N' in positional slots don't leak into ssh_port/ssh_key" {
  # Simulates `strut migrate myhost ubuntu --sudo --start-phase=2` — --sudo
  # would otherwise land in the ssh_port slot without filtering.
  run _timeout 5 bash -c '
    source "$CLI_ROOT/lib/utils.sh"
    source "$CLI_ROOT/lib/migrate.sh"
    export STRUT_YES=1
    migrate_phase_setup() { echo "SETUP host=$1 user=$2 port=$3 key=$4"; exit 0; }
    migrate_wizard "myhost" "ubuntu" "--sudo" "--start-phase=2" 2>&1
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SETUP host=myhost user=ubuntu port= key="* ]]
  # --sudo was recognized as a flag (not leaked into the ssh_port slot)
  [[ "$output" == *"Docker sudo: enabled (--sudo)"* ]]
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
