#!/usr/bin/env bats
# ==================================================
# tests/test_drift_schedule.bats — Tests for drift cron job installation
# ==================================================
# Run:  bats tests/test_drift_schedule.bats
# Covers: drift_schedule_install, drift_autofix_enable, drift_autofix_disable
# cron line shape. Fakes crontab as a shell function backed by a temp file —
# never touches the real system crontab. The write side goes through a
# temp-file-then-rename so a read (-l) landing in the same pipeline as a
# write (-) never observes a truncated file — the same atomicity the real
# crontab binary provides.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }

  export RED GREEN YELLOW BLUE NC
  source "$CLI_ROOT/lib/drift/schedule.sh"
  source "$CLI_ROOT/lib/drift/autofix.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-drift-sched-"*
  rm -rf "$TEST_TMP"
}

_fake_crontab_setup() {
  FAKE_CRONTAB="$TEST_TMP/crontab.txt"
  : > "$FAKE_CRONTAB"
  crontab() {
    case "$1" in
      -l) cat "$FAKE_CRONTAB" 2>/dev/null ;;
      -)
        local tmp
        tmp="$(mktemp)"
        cat > "$tmp"
        mv "$tmp" "$FAKE_CRONTAB"
        ;;
    esac
  }
}

# ── drift_schedule_install ────────────────────────────────────────────────────

@test "drift_schedule_install: cron line invokes absolute strut binary, never bare 'strut'" {
  local stack="test-drift-sched-cron-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  _fake_crontab_setup

  run drift_schedule_install "$stack" "prod"
  [ "$status" -eq 0 ]

  local line
  line=$(grep "drift monitor" "$FAKE_CRONTAB")
  [[ "$line" == *"$CLI_ROOT/strut"* ]]
  [[ "$line" != *" strut "* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "drift_schedule_install: adds PATH/SHELL header and wraps command in flock" {
  local stack="test-drift-sched-header-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  rm -rf "$CLI_ROOT/stacks/$stack/drift-history"
  _fake_crontab_setup

  run drift_schedule_install "$stack" "prod"
  [ "$status" -eq 0 ]
  [ -d "$CLI_ROOT/stacks/$stack/drift-history" ]
  grep -q "^PATH=" "$FAKE_CRONTAB"
  grep -q "^SHELL=" "$FAKE_CRONTAB"
  grep -q "flock -n" "$FAKE_CRONTAB"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "drift_schedule_install: installed cron line runs end-to-end under a minimal cron PATH" {
  local stack="test-drift-sched-e2e-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  _fake_crontab_setup

  drift_schedule_install "$stack" "prod" >/dev/null

  local line
  line=$(grep "drift monitor" "$FAKE_CRONTAB")
  # Strip the 5-field schedule, keep the rest of the command
  local remainder
  remainder=$(echo "$line" | cut -d' ' -f6-)

  run env -i PATH=/usr/bin:/bin HOME="${HOME:-/root}" sh -c "$remainder"
  [[ "$output" != *"command not found"* ]]

  local log_file="$CLI_ROOT/stacks/$stack/drift-history/monitor.log"
  [ -f "$log_file" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "drift_schedule_install: does not duplicate an existing cron job" {
  local stack="test-drift-sched-dup-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  _fake_crontab_setup

  drift_schedule_install "$stack" "prod" >/dev/null
  run drift_schedule_install "$stack" "prod"
  [ "$status" -eq 0 ]

  local count
  count=$(grep -c "drift monitor" "$FAKE_CRONTAB")
  [ "$count" -eq 1 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── drift_autofix_enable / drift_autofix_disable ──────────────────────────────

@test "drift_autofix_enable: cron line invokes absolute strut binary with --auto-fix" {
  local stack="test-drift-sched-autofix-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  _fake_crontab_setup

  run drift_autofix_enable "$stack" "prod"
  [ "$status" -eq 0 ]

  local line
  line=$(grep "drift monitor" "$FAKE_CRONTAB")
  [[ "$line" == *"$CLI_ROOT/strut"* ]]
  [[ "$line" != *" strut "* ]]
  [[ "$line" == *"--auto-fix"* ]]
  grep -q "flock -n" "$FAKE_CRONTAB"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "drift_autofix_disable: cron line invokes absolute strut binary without --auto-fix" {
  local stack="test-drift-sched-noautofix-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  _fake_crontab_setup

  drift_autofix_enable "$stack" "prod" >/dev/null
  run drift_autofix_disable "$stack"
  [ "$status" -eq 0 ]

  local line
  line=$(grep "drift monitor" "$FAKE_CRONTAB")
  [[ "$line" == *"$CLI_ROOT/strut"* ]]
  [[ "$line" != *" strut "* ]]
  [[ "$line" != *"--auto-fix"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}
