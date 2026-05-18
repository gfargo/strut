#!/usr/bin/env bats
# ==================================================
# tests/test_remote_init.bats — Unit tests for remote:init command
# ==================================================
# Run:  bats tests/test_remote_init.bats

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  # Source required modules
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/cmd_remote_init.sh"

  # Override fail/log/ok/warn/print_banner to not exit or clutter output
  fail() { echo "FAIL: $1" >&2; return 1; }
  log() { :; }
  ok() { :; }
  warn() { :; }
  print_banner() { :; }

  # Stub build_ssh_opts to return predictable output
  build_ssh_opts() { echo "-o BatchMode=yes"; }

  # Default CMD_* exports
  export CMD_STACK=""
  export CMD_ENV_FILE=""
  export CMD_ENV_NAME=""
  export DRY_RUN="false"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── Usage ─────────────────────────────────────────────────────────────────────

@test "remote:init: _usage_remote_init prints help text" {
  result=$(_usage_remote_init)
  [[ "$result" == *"Bootstrap strut on a remote VPS"* ]]
  [[ "$result" == *"--host"* ]]
  [[ "$result" == *"--user"* ]]
  [[ "$result" == *"--repo"* ]]
}

# ── Validation ────────────────────────────────────────────────────────────────

@test "remote:init: fails when no host is provided" {
  # No VPS_HOST, no --host flag
  unset VPS_HOST
  run cmd_remote_init
  [ "$status" -eq 1 ]
  [[ "$output" == *"VPS_HOST is required"* ]]
}

@test "remote:init: fails when no repo URL can be detected" {
  export VPS_HOST="test-host"
  # Override git to return nothing
  git() { return 1; }
  export -f git

  run cmd_remote_init
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not detect git remote URL"* ]]
}

# ── Dry-run mode ──────────────────────────────────────────────────────────────

@test "remote:init: dry-run shows execution plan without executing" {
  export VPS_HOST="test-host"
  export VPS_USER="ubuntu"
  export DRY_RUN="true"

  # Stub git remote detection
  git() { echo "https://github.com/user/repo.git"; }
  export -f git

  # Stub run_cmd to just echo
  run_cmd() { echo "PLAN: $1"; }
  export -f run_cmd

  # Need color vars
  YELLOW=""
  NC=""
  export YELLOW NC

  run cmd_remote_init
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

# ── Flag parsing ──────────────────────────────────────────────────────────────

@test "remote:init: --host and --user override env vars" {
  export VPS_HOST="env-host"
  export VPS_USER="env-user"
  export DRY_RUN="true"

  git() { echo "https://github.com/user/repo.git"; }
  export -f git
  run_cmd() { echo "PLAN: $1"; }
  export -f run_cmd
  YELLOW=""
  NC=""
  export YELLOW NC

  # Re-source to get clean state
  source "$CLI_ROOT/lib/cmd_remote_init.sh"
  fail() { echo "FAIL: $1" >&2; return 1; }
  log() { :; }
  ok() { :; }
  warn() { :; }
  print_banner() { :; }
  build_ssh_opts() { echo "-o BatchMode=yes"; }

  run cmd_remote_init --host override-host --user override-user
  [ "$status" -eq 0 ]
  # The dry-run output should reference the overridden host
  [[ "$output" == *"override-host"* ]] || [[ "$output" == *"DRY-RUN"* ]]
}

@test "remote:init: --repo flag overrides git remote detection" {
  export VPS_HOST="test-host"
  export DRY_RUN="true"

  # git should NOT be called when --repo is provided
  git() { echo "SHOULD_NOT_APPEAR"; }
  export -f git
  run_cmd() { echo "PLAN: $1"; }
  export -f run_cmd
  YELLOW=""
  NC=""
  export YELLOW NC

  run cmd_remote_init --repo "https://github.com/custom/repo.git"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_APPEAR"* ]]
}
