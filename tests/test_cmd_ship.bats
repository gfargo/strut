#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_ship.bats — Tests for lib/cmd_ship.sh
# ==================================================
# Run:  bats tests/test_cmd_ship.bats
# Covers: cmd_ship dry-run mode, argument parsing, usage output

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  source "$CLI_ROOT/lib/output.sh"
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "BANNER: $*"; }
  run_cmd() { echo "RUN: $*"; }
  export -f fail ok warn log error print_banner run_cmd

  # Stub validate_env_file to source a test env and set VPS_* vars
  validate_env_file() {
    local env_file="$1"; shift
    [ -f "$env_file" ] || { fail "Env file not found: $env_file"; return 1; }
    set -a; source "$env_file"; set +a
  }
  export -f validate_env_file

  # Stub build_ssh_opts
  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  export -f build_ssh_opts

  source "$CLI_ROOT/lib/cmd_ship.sh"

  # Create test fixtures
  STACK="demo"
  mkdir -p "$TEST_TMP/stacks/$STACK"
  cat > "$TEST_TMP/stacks/$STACK/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx
EOF

  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
VPS_USER=deploy
VPS_SSH_KEY=~/.ssh/id_rsa
VPS_PORT=22
VPS_DEPLOY_DIR=/home/deploy/strut
EOF

  export CLI_ROOT="$TEST_TMP"
  export CMD_STACK="$STACK"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export CMD_ENV_NAME="prod"
}

teardown() { common_teardown; }

# ── Usage ─────────────────────────────────────────────────────────────────────

@test "_usage_ship: prints usage information" {
  run _usage_ship
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--env"* ]]
  [[ "$output" == *"--message"* ]]
  [[ "$output" == *"--no-commit"* ]]
  [[ "$output" == *"--no-push"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

# ── Dry-run mode ──────────────────────────────────────────────────────────────

@test "cmd_ship: dry-run shows execution plan without side effects" {
  export DRY_RUN=false

  run cmd_ship --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]
  # Should show the planned steps
  [[ "$output" == *"Stage and commit"* ]] || [[ "$output" == *"RUN:"* ]]
}

@test "cmd_ship: dry-run with --no-commit skips commit step" {
  export DRY_RUN=false

  run cmd_ship --dry-run --no-commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  # Should not show commit step
  [[ "$output" != *"Stage and commit"* ]]
  # Should still show push and rebuild
  [[ "$output" == *"Push to origin"* ]] || [[ "$output" == *"push"* ]]
}

@test "cmd_ship: dry-run with --no-push skips push step" {
  export DRY_RUN=false

  run cmd_ship --dry-run --no-push
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  # Should not show push step
  [[ "$output" != *"Push to origin"* ]]
}

@test "cmd_ship: dry-run with --no-cache passes flag to remote rebuild" {
  export DRY_RUN=false

  run cmd_ship --dry-run --no-cache
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-cache"* ]]
}

@test "cmd_ship: dry-run with --platform passes flag to remote rebuild" {
  export DRY_RUN=false

  run cmd_ship --dry-run --platform linux/arm64,linux/amd64
  [ "$status" -eq 0 ]
  [[ "$output" == *"--platform linux/arm64,linux/amd64"* ]]
}

@test "cmd_ship: dry-run with custom message" {
  export DRY_RUN=false

  run cmd_ship --dry-run -m "fix bug #42"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix bug #42"* ]]
}

@test "cmd_ship: dry-run resolves connection info from env file" {
  export DRY_RUN=false

  run cmd_ship --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"10.0.0.1"* ]]
  [[ "$output" == *"deploy"* ]]
}

# ── Error cases ───────────────────────────────────────────────────────────────

@test "cmd_ship: fails when env file is missing" {
  export CMD_ENV_FILE="$TEST_TMP/nonexistent.env"

  # Use exit-based fail() in the run subshell so the function aborts
  validate_env_file() {
    local env_file="$1"; shift
    [ -f "$env_file" ] || { echo "FAIL: Env file not found: $env_file" >&2; exit 1; }
    set -a; source "$env_file"; set +a
  }
  export -f validate_env_file

  run cmd_ship --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"FAIL"* ]]
}
