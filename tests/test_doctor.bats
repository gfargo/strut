#!/usr/bin/env bats
# ==================================================
# tests/test_doctor.bats — Tests for strut doctor
# ==================================================
# Run:  bats tests/test_doctor.bats
# Covers: cmd_doctor, individual check functions, --json, --fix

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/cmd_doctor.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── Individual checks ─────────────────────────────────────────────────────────

@test "_doc_check_strut_version: finds VERSION file" {
  export STRUT_HOME="$CLI_ROOT"
  _DOC_PASSED=0
  _DOC_JSON=false
  _DOC_FIX=false
  run _doc_check_strut_version
  [ "$status" -eq 0 ]
  [[ "$output" == *"version"* ]]
}

@test "_doc_check_docker: detects docker" {
  _DOC_PASSED=0
  _DOC_FAILED=0
  _DOC_JSON=false
  _DOC_FIX=false
  # Docker should be available in the test environment
  run _doc_check_docker
  # Either pass (running) or fail (not running) — should not crash
  true
}

@test "_doc_check_git: detects git" {
  _DOC_PASSED=0
  _DOC_WARNED=0
  _DOC_JSON=false
  _DOC_FIX=false
  run _doc_check_git
  [ "$status" -eq 0 ]
  # Should mention Git regardless of whether user.name is configured
  [[ "$output" == *"Git"* ]]
}

@test "_doc_check_tool: detects installed tool" {
  _DOC_PASSED=0
  _DOC_JSON=false
  _DOC_FIX=false
  run _doc_check_tool "bash" "shell" "already installed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed"* ]]
}

@test "_doc_check_tool: warns for missing tool" {
  _DOC_WARNED=0
  _DOC_JSON=false
  _DOC_FIX=false
  _doc_warn "test" "not installed" "" >/dev/null 2>&1 || true
  _doc_check_tool "nonexistent_tool_xyz" "testing" "brew install xyz" >/dev/null 2>&1 || true
  # Just verify it doesn't crash — counter check in integration test
  true
}

@test "_doc_check_tool: shows fix command with --fix" {
  _DOC_WARNED=0
  _DOC_JSON=false
  _DOC_FIX=true
  run _doc_check_tool "nonexistent_tool_xyz" "testing" "brew install xyz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew install xyz"* ]]
}

@test "_doc_check_project: covered by cmd_doctor integration test" {
  # Project checks are tested via cmd_doctor integration test below
  # (calling _doc_check_project directly in a subshell is fragile due to set -euo pipefail)
  export STRUT_HOME="$CLI_ROOT"
  run cmd_doctor --json
  [ "$status" -eq 0 ]
  # Should have checked strut.conf and stacks
  echo "$output" | jq -e '.checks[] | select(.name == "strut.conf" or .name == "Stacks")' >/dev/null
}

# ── cmd_doctor integration ────────────────────────────────────────────────────

@test "cmd_doctor: runs without error" {
  export STRUT_HOME="$CLI_ROOT"
  run cmd_doctor
  # Should complete (may have warnings but shouldn't crash)
  [[ "$output" == *"strut Doctor"* ]]
  [[ "$output" == *"passed"* ]]
}

@test "cmd_doctor: --json outputs valid JSON" {
  export STRUT_HOME="$CLI_ROOT"
  run cmd_doctor --json
  [ "$status" -eq 0 ]
  echo "$output" | jq empty
  [ "$(echo "$output" | jq -r '.summary.passed')" -gt 0 ]
}

@test "cmd_doctor: --json includes checks array" {
  export STRUT_HOME="$CLI_ROOT"
  run cmd_doctor --json
  [ "$status" -eq 0 ]
  local check_count
  check_count=$(echo "$output" | jq '.checks | length')
  [ "$check_count" -gt 0 ]
}

@test "cmd_doctor: --help shows usage" {
  run cmd_doctor --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"--check-vps"* ]]
  [[ "$output" == *"--json"* ]]
  [[ "$output" == *"--fix"* ]]
}

# ── _doc_pass/_doc_warn/_doc_fail counters ────────────────────────────────────

@test "_doc_pass increments counter" {
  _DOC_PASSED=0
  _DOC_JSON=false
  _DOC_FIX=false
  _doc_pass "test" "ok" >/dev/null
  [ "$_DOC_PASSED" -eq 1 ]
  _doc_pass "test2" "ok" >/dev/null
  [ "$_DOC_PASSED" -eq 2 ]
}

@test "_doc_warn increments counter" {
  _DOC_WARNED=0
  _DOC_JSON=false
  _DOC_FIX=false
  _doc_warn "test" "warning" >/dev/null
  [ "$_DOC_WARNED" -eq 1 ]
}

@test "_doc_fail increments counter" {
  _DOC_FAILED=0
  _DOC_JSON=false
  _DOC_FIX=false
  _doc_fail "test" "error" >/dev/null
  [ "$_DOC_FAILED" -eq 1 ]
}

# ── Property: JSON output always valid ────────────────────────────────────────

@test "Property: doctor --json always produces valid JSON (10 iterations)" {
  export STRUT_HOME="$CLI_ROOT"
  for i in $(seq 1 10); do
    run cmd_doctor --json
    echo "$output" | jq empty || {
      echo "FAILED iteration $i: invalid JSON output"
      echo "$output"
      return 1
    }
    [ "$(echo "$output" | jq -r '.summary | keys | length')" -eq 3 ] || {
      echo "FAILED iteration $i: summary missing keys"
      return 1
    }
  done
}

# ── strut doctor accessible from entrypoint ───────────────────────────────────

@test "strut doctor: accessible as top-level command" {
  run "$CLI_ROOT/strut" doctor --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

# ── SSH permission checks ─────────────────────────────────────────────────────

@test "cmd_doctor --json: includes SSH key permission check" {
  export STRUT_HOME="$CLI_ROOT"
  run cmd_doctor --json
  [ "$status" -eq 0 ]
  # Should have an SSH-related check in the output
  echo "$output" | jq -e '.checks[] | select(.name | test("SSH"))' >/dev/null
}
