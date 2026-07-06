#!/usr/bin/env bats
# ==================================================
# tests/test_backup_schedule.bats — Tests for backup scheduling
# ==================================================
# Run:  bats tests/test_backup_schedule.bats
# Covers: validate_cron_expression, create_default_backup_conf

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/backup.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-sched-"*
  rm -rf "$TEST_TMP"
}

# ── validate_cron_expression ──────────────────────────────────────────────────

@test "validate_cron_expression: accepts valid 5-field expression" {
  run validate_cron_expression "0 2 * * *"
  [ "$status" -eq 0 ]
}

@test "validate_cron_expression: accepts weekly expression" {
  run validate_cron_expression "0 3 * * 0"
  [ "$status" -eq 0 ]
}

@test "validate_cron_expression: accepts every-minute expression" {
  run validate_cron_expression "* * * * *"
  [ "$status" -eq 0 ]
}

@test "validate_cron_expression: rejects too few fields" {
  run validate_cron_expression "0 2 *"
  [ "$status" -eq 1 ]
}

@test "validate_cron_expression: rejects too many fields" {
  run validate_cron_expression "0 2 * * * *"
  [ "$status" -eq 1 ]
}

@test "validate_cron_expression: rejects empty string" {
  run validate_cron_expression ""
  [ "$status" -eq 1 ]
}

# ── Property: valid cron expressions always have 5 fields ─────────────────────

@test "Property: valid cron expressions accepted, invalid rejected (100 iterations)" {
  for i in $(seq 1 100); do
    # Generate random field count between 1 and 7
    local field_count=$(( (RANDOM % 7) + 1 ))
    local expr=""
    for j in $(seq 1 "$field_count"); do
      [ -n "$expr" ] && expr="$expr "
      expr="${expr}*"
    done

    if [ "$field_count" -eq 5 ]; then
      run validate_cron_expression "$expr"
      [ "$status" -eq 0 ] || {
        echo "FAILED: 5-field expression '$expr' should be valid"
        return 1
      }
    else
      run validate_cron_expression "$expr"
      [ "$status" -eq 1 ] || {
        echo "FAILED: ${field_count}-field expression '$expr' should be invalid"
        return 1
      }
    fi
  done
}

# ── create_default_backup_conf ────────────────────────────────────────────────

@test "create_default_backup_conf: creates file with expected keys" {
  local stack="test-sched-default-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  run create_default_backup_conf "$stack"
  [ "$status" -eq 0 ]

  local conf="$CLI_ROOT/stacks/$stack/backup.conf"
  [ -f "$conf" ]
  grep -q "BACKUP_SCHEDULE_POSTGRES" "$conf"
  grep -q "BACKUP_SCHEDULE_NEO4J" "$conf"
  grep -q "BACKUP_RETAIN_DAYS" "$conf"
  grep -q "BACKUP_RETAIN_COUNT" "$conf"
  grep -q "BACKUP_POSTGRES=true" "$conf"
  grep -q "BACKUP_NEO4J=true" "$conf"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "create_default_backup_conf: file is sourceable" {
  local stack="test-sched-source-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  create_default_backup_conf "$stack" >/dev/null 2>&1

  # Should be sourceable without errors
  run bash -c "source '$CLI_ROOT/stacks/$stack/backup.conf'"
  [ "$status" -eq 0 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── install_backup_schedule: cron line shape ──────────────────────────────────
# Fakes crontab as a shell function backed by a temp file — never touches the
# real system crontab. Mirrors the fail()/error() override pattern above.
# The write side goes through a temp-file-then-rename so a read (-l) that
# lands in the same pipeline as a write (-) can never observe a truncated
# file — the same atomicity the real crontab binary provides.

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

@test "install_backup_schedule: cron line invokes absolute strut binary, never bare 'strut'" {
  local stack="test-sched-cron-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  _fake_crontab_setup

  run install_backup_schedule "$stack" "postgres" "0 2 * * *" "prod"
  [ "$status" -eq 0 ]

  local line
  line=$(grep -A1 "strut backup: $stack/postgres" "$FAKE_CRONTAB" | tail -1)
  [[ "$line" == *"$CLI_ROOT/strut"* ]]
  [[ "$line" != *" strut "* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "install_backup_schedule: adds PATH/SHELL header once, idempotent on reinstall" {
  local stack="test-sched-header-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  _fake_crontab_setup

  install_backup_schedule "$stack" "postgres" "0 2 * * *" "prod" >/dev/null
  install_backup_schedule "$stack" "postgres" "0 3 * * *" "prod" >/dev/null

  local path_count
  path_count=$(grep -c "^PATH=" "$FAKE_CRONTAB")
  [ "$path_count" -eq 1 ]
  grep -q "^SHELL=" "$FAKE_CRONTAB"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "install_backup_schedule: creates log directory and wraps command in flock" {
  local stack="test-sched-log-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  rm -rf "$CLI_ROOT/stacks/$stack/backups"
  _fake_crontab_setup

  run install_backup_schedule "$stack" "postgres" "0 2 * * *" "prod"
  [ "$status" -eq 0 ]
  [ -d "$CLI_ROOT/stacks/$stack/backups" ]
  grep -q "flock -n" "$FAKE_CRONTAB"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "install_backup_schedule: installed cron line runs end-to-end under a minimal cron PATH" {
  local stack="test-sched-e2e-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  _fake_crontab_setup

  install_backup_schedule "$stack" "postgres" "0 2 * * *" "prod" >/dev/null

  local line
  line=$(grep "^0 2" "$FAKE_CRONTAB")
  # Strip the 5-field schedule, keep the rest of the command
  local remainder
  remainder=$(echo "$line" | cut -d' ' -f6-)

  run env -i PATH=/usr/bin:/bin HOME="${HOME:-/root}" sh -c "$remainder"
  [[ "$output" != *"command not found"* ]]

  local log_file="$CLI_ROOT/stacks/$stack/backups/cron.log"
  [ -f "$log_file" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}
