#!/usr/bin/env bats
# ==================================================
# tests/test_log_helpers.bats — Tests for log, ok, warn, fail, error
# ==================================================
# Run:  bats tests/test_log_helpers.bats

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

_load_utils() {
  source "$CLI_ROOT/lib/utils.sh"
}

# ── log ───────────────────────────────────────────────────────────────────────

@test "log: outputs message with [strut] prefix" {
  _load_utils
  result=$(log "hello world")
  [[ "$result" == *"[strut]"* ]]
  [[ "$result" == *"hello world"* ]]
}

# ── ok ────────────────────────────────────────────────────────────────────────

@test "ok: outputs message with checkmark" {
  _load_utils
  result=$(ok "success")
  [[ "$result" == *"✓"* ]]
  [[ "$result" == *"success"* ]]
}

# ── warn ──────────────────────────────────────────────────────────────────────

@test "warn: outputs message with warning symbol" {
  _load_utils
  result=$(warn "caution")
  [[ "$result" == *"⚠"* ]]
  [[ "$result" == *"caution"* ]]
}

# ── error ─────────────────────────────────────────────────────────────────────

@test "error: outputs to stderr with cross symbol" {
  _load_utils
  result=$(error "bad thing" 2>&1)
  [[ "$result" == *"✗"* ]]
  [[ "$result" == *"bad thing"* ]]
}

@test "error: does not exit (unlike fail)" {
  _load_utils
  # error should return, not exit
  run bash -c "source '$CLI_ROOT/lib/utils.sh'; error 'test'; echo 'still running'"
  [[ "$output" == *"still running"* ]]
}

# ── fail ──────────────────────────────────────────────────────────────────────

@test "fail: exits with code 1" {
  run bash -c "source '$CLI_ROOT/lib/utils.sh'; fail 'fatal error'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗"* ]]
  [[ "$output" == *"fatal error"* ]]
}

@test "fail: outputs to stderr" {
  run bash -c "source '$CLI_ROOT/lib/utils.sh'; fail 'fatal' 2>/dev/null"
  # With stderr suppressed, stdout should be empty
  [ -z "$output" ]
}
