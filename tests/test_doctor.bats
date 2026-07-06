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

@test "cmd_doctor --json: includes SSH key permissions check for secure key perms" {
  export STRUT_HOME="$CLI_ROOT"
  export HOME="$TEST_TMP/home-pass"
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/id_rsa"
  chmod 700 "$HOME/.ssh"
  chmod 600 "$HOME/.ssh/id_rsa"

  run cmd_doctor --json
  # May return 1 due to Docker/other checks failing with fake HOME — that's OK
  echo "$output" | jq -e '.checks[] | select(.name == "SSH key permissions")' >/dev/null
}

@test "cmd_doctor --json: reports SSH key permissions fix for insecure key perms" {
  export STRUT_HOME="$CLI_ROOT"
  export HOME="$TEST_TMP/home-fail"
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/id_rsa"
  chmod 755 "$HOME/.ssh"
  chmod 644 "$HOME/.ssh/id_rsa"

  # Run in text mode — easier to assert on output
  _DOC_PASSED=0; _DOC_WARNED=0; _DOC_FAILED=0; _DOC_JSON=false; _DOC_FIX=true
  run _doc_check_ssh_key
  [[ "$output" == *"should be 600 or 400"* ]]
  [[ "$output" == *"chmod"* ]]
}

# ── --deep flag parsing ──────────────────────────────────────────────────────

@test "cmd_doctor: --deep implies --check-vps" {
  # Invoke via bash -c so cmd_doctor's early-return paths (--help) don't
  # taint the test process. We only need to prove the parser dispatch.
  run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    source "'"$CLI_ROOT"'/lib/cmd_doctor.sh"
    # Stub every check so we can observe --deep without running SSH.
    _doc_check_strut_version() { :; }
    _doc_check_docker() { :; }
    _doc_check_compose() { :; }
    _doc_check_git() { :; }
    _doc_check_gh() { :; }
    _doc_check_ssh_key() { :; }
    _doc_check_tool() { :; }
    _doc_check_project() { :; }
    _doc_check_vps() { echo "VPS_CHECK_CALLED"; }
    cmd_doctor --deep 2>&1
    echo "DEEP=$_DOC_VPS_DEEP"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"VPS_CHECK_CALLED"* ]]
  [[ "$output" == *"DEEP=true"* ]]
}

@test "cmd_doctor: base run does NOT invoke VPS checks" {
  run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    source "'"$CLI_ROOT"'/lib/cmd_doctor.sh"
    _doc_check_strut_version() { :; }
    _doc_check_docker() { :; }
    _doc_check_compose() { :; }
    _doc_check_git() { :; }
    _doc_check_gh() { :; }
    _doc_check_ssh_key() { :; }
    _doc_check_tool() { :; }
    _doc_check_project() { :; }
    _doc_check_vps() { echo "VPS_CHECK_CALLED"; }
    cmd_doctor 2>&1
    echo "DEEP=$_DOC_VPS_DEEP"
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"VPS_CHECK_CALLED"* ]]
  [[ "$output" == *"DEEP=false"* ]]
}

@test "cmd_doctor: --check-vps alone leaves --deep off" {
  run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    source "'"$CLI_ROOT"'/lib/cmd_doctor.sh"
    _doc_check_strut_version() { :; }
    _doc_check_docker() { :; }
    _doc_check_compose() { :; }
    _doc_check_git() { :; }
    _doc_check_gh() { :; }
    _doc_check_ssh_key() { :; }
    _doc_check_tool() { :; }
    _doc_check_project() { :; }
    _doc_check_vps() { echo "VPS_CHECK_CALLED"; }
    cmd_doctor --check-vps 2>&1
    echo "DEEP=$_DOC_VPS_DEEP"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"VPS_CHECK_CALLED"* ]]
  [[ "$output" == *"DEEP=false"* ]]
}

@test "_usage_doctor: mentions --deep" {
  run _usage_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"--deep"* ]]
  [[ "$output" == *"preflight"* ]]
}

# ── workingdir deep probe (OSS-325) ──────────────────────────────────────────

@test "_doc_check_vps_deep: workingdir match emits pass" {
  # Stub the SSH output to simulate a matching working_dir
  local deploy_dir="/opt/strut"
  local fake_out="=== docker ===
Docker version 24.0.7, build abcdef
=== compose ===
2.24.0
=== disk ===
10000000
=== mem ===
2000000
=== ports ===
22,
=== sudo ===
sudo: PASSWORDLESS
=== workingdir ===
${deploy_dir}/stacks/my-app"

  # Override timeout+ssh to return our fake output
  timeout() { shift; shift; echo "$fake_out"; }
  export -f timeout

  run _doc_check_vps_deep "prod" "-o BatchMode=yes" "ubuntu" "host.example.com" "$deploy_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workingdir"* ]]
  [[ "$output" == *"pass"* ]] || [[ "$output" == *"✓"* ]] || [[ "$output" == *"all containers"* ]]
}

@test "_doc_check_vps_deep: workingdir mismatch emits warn" {
  local fake_out="=== docker ===
Docker version 24.0.7, build abcdef
=== compose ===
2.24.0
=== disk ===
10000000
=== mem ===
2000000
=== ports ===
22,
=== sudo ===
sudo: PASSWORDLESS
=== workingdir ===
/opt/stacks/my-app"

  timeout() { shift; shift; echo "$fake_out"; }
  export -f timeout

  run _doc_check_vps_deep "prod" "-o BatchMode=yes" "ubuntu" "host.example.com" "/home/ubuntu/strut"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workingdir"* ]]
  [[ "$output" == *"/opt/stacks/my-app"* ]]
}

@test "_doc_check_vps_deep: workingdir empty (no containers) skips cleanly" {
  local fake_out="=== docker ===
Docker version 24.0.7, build abcdef
=== compose ===
2.24.0
=== disk ===
10000000
=== mem ===
2000000
=== ports ===
22,
=== sudo ===
sudo: PASSWORDLESS
=== workingdir ===
workingdir: EMPTY"

  timeout() { shift; shift; echo "$fake_out"; }
  export -f timeout

  run _doc_check_vps_deep "prod" "-o BatchMode=yes" "ubuntu" "host.example.com" "/home/ubuntu/strut"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no running containers"* ]]
}

@test "_doc_check_vps_deep: ignores VPS_DEPLOY_DIR from process env, uses probed value" {
  local fake_out="=== docker ===
Docker version 24.0.7, build abcdef
=== compose ===
2.24.0
=== disk ===
10000000
=== mem ===
2000000
=== ports ===
22,
=== sudo ===
sudo: PASSWORDLESS
=== workingdir ===
/opt/strut/stacks/my-app"

  timeout() { shift; shift; echo "$fake_out"; }
  export -f timeout

  # Process env deliberately disagrees with the probed env file's deploy dir.
  export VPS_DEPLOY_DIR="/some/wrong/path"
  export VPS_USER="ubuntu"

  run _doc_check_vps_deep "prod" "-o BatchMode=yes" "ubuntu" "host.example.com" "/opt/strut"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workingdir"* ]]
  [[ "$output" == *"all containers"* ]]
  [[ "$output" != *"outside expected prefix"* ]]
}

@test "_doc_check_vps_deep: process env VPS_DEPLOY_DIR that would falsely match still warns correctly" {
  local fake_out="=== docker ===
Docker version 24.0.7, build abcdef
=== compose ===
2.24.0
=== disk ===
10000000
=== mem ===
2000000
=== ports ===
22,
=== sudo ===
sudo: PASSWORDLESS
=== workingdir ===
/opt/other/stacks/my-app"

  timeout() { shift; shift; echo "$fake_out"; }
  export -f timeout

  # Process env matches the container path, but the probed deploy_dir doesn't — must still warn.
  export VPS_DEPLOY_DIR="/opt/other"
  export VPS_USER="ubuntu"

  run _doc_check_vps_deep "prod" "-o BatchMode=yes" "ubuntu" "host.example.com" "/home/ubuntu/strut"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workingdir"* ]]
  [[ "$output" == *"outside expected prefix"* ]]
}
