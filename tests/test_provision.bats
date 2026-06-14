#!/usr/bin/env bats
# ==================================================
# tests/test_provision.bats — Tests for lib/cmd_provision.sh
# ==================================================
# Run:  bats tests/test_provision.bats
# Covers: _provision_find_script, _usage_provision, cmd_provision dry-run

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "BANNER: $*"; }
  run_cmd() { echo "RUN: $*"; }
  export -f fail ok warn log error print_banner run_cmd

  # Stub build_ssh_opts
  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  export -f build_ssh_opts

  source "$CLI_ROOT/lib/cmd_provision.sh"

  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
}

teardown() { common_teardown; }

# ── _usage_provision ──────────────────────────────────────────────────────────

@test "_usage_provision: prints usage information" {
  run _usage_provision
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--script"* ]]
  [[ "$output" == *"--verify"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "_usage_provision: includes examples" {
  run _usage_provision
  [ "$status" -eq 0 ]
  [[ "$output" == *"Examples:"* ]]
  [[ "$output" == *"provision"* ]]
}

# ── _provision_find_script ────────────────────────────────────────────────────

@test "_provision_find_script: finds scripts/provision-<host>.sh" {
  mkdir -p "$TEST_TMP/scripts"
  touch "$TEST_TMP/scripts/provision-harbor.sh"

  result=$(_provision_find_script "harbor")
  [ "$result" = "$TEST_TMP/scripts/provision-harbor.sh" ]
}

@test "_provision_find_script: finds infra/scripts/provision-<host>.sh" {
  mkdir -p "$TEST_TMP/infra/scripts"
  touch "$TEST_TMP/infra/scripts/provision-compass.sh"

  result=$(_provision_find_script "compass")
  [ "$result" = "$TEST_TMP/infra/scripts/provision-compass.sh" ]
}

@test "_provision_find_script: prefers scripts/ over infra/scripts/" {
  mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/infra/scripts"
  touch "$TEST_TMP/scripts/provision-node1.sh"
  touch "$TEST_TMP/infra/scripts/provision-node1.sh"

  result=$(_provision_find_script "node1")
  [ "$result" = "$TEST_TMP/scripts/provision-node1.sh" ]
}

@test "_provision_find_script: uses explicit path when provided" {
  mkdir -p "$TEST_TMP/custom"
  touch "$TEST_TMP/custom/my-script.sh"

  result=$(_provision_find_script "harbor" "$TEST_TMP/custom/my-script.sh")
  [ "$result" = "$TEST_TMP/custom/my-script.sh" ]
}

@test "_provision_find_script: returns 1 when explicit path doesn't exist" {
  run _provision_find_script "harbor" "/nonexistent/script.sh"
  [ "$status" -eq 1 ]
}

@test "_provision_find_script: returns 1 when no script found" {
  run _provision_find_script "unknown-host"
  [ "$status" -eq 1 ]
}

# ── cmd_provision dry-run ─────────────────────────────────────────────────────

@test "cmd_provision: dry-run shows execution plan" {
  mkdir -p "$TEST_TMP/scripts"
  echo "#!/bin/bash" > "$TEST_TMP/scripts/provision-harbor.sh"

  # Stub topology
  source "$CLI_ROOT/lib/topology.sh" 2>/dev/null || true
  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"
  export VPS_PORT="22"

  export CMD_STACK="harbor"
  export DRY_RUN=false

  run cmd_provision --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]
  [[ "$output" == *"SSH connectivity"* ]] || [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"provision"* ]]
}

@test "cmd_provision: dry-run with --verify shows verify mode" {
  mkdir -p "$TEST_TMP/scripts"
  echo "#!/bin/bash" > "$TEST_TMP/scripts/provision-harbor.sh"

  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"

  export CMD_STACK="harbor"
  export DRY_RUN=false

  run cmd_provision --verify --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--verify"* ]]
}

@test "cmd_provision: fails when no host alias provided" {
  export CMD_STACK=""

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_provision --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Host alias required"* ]]
}

@test "cmd_provision: fails when no provision script found" {
  export CMD_STACK="unknown-host"

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"

  run cmd_provision --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"No provision script found"* ]] || [[ "$output" == *"provision-unknown-host.sh"* ]]
}

@test "cmd_provision: fails when host cannot be resolved" {
  mkdir -p "$TEST_TMP/scripts"
  echo "#!/bin/bash" > "$TEST_TMP/scripts/provision-orphan.sh"

  export CMD_STACK="orphan"
  unset VPS_HOST

  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_provision --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot resolve host"* ]]
}
