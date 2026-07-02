#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_status_remote.bats — Remote dispatch for status/health/logs
# ==================================================
# Verifies that cmd_status, cmd_health, cmd_logs, and cmd_logs_download
# SSH to the VPS when VPS_HOST is set and we are not already on the host,
# and fall back to local Docker when VPS_HOST is unset or is_running_on_vps.
# Run: bats tests/test_cmd_status_remote.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/cmd_deploy.sh"
  source "$CLI_ROOT/lib/cmd_logs.sh"

  # Create a minimal test stack + env file
  mkdir -p "$TEST_TMP/stacks/test-stack"
  echo "services:" > "$TEST_TMP/stacks/test-stack/docker-compose.yml"
  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"

  # Default: not on VPS (will be overridden per test)
  is_running_on_vps() { return 1; }
  export -f is_running_on_vps

  # Stub resolve_compose_cmd so local tests don't need Docker
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd

  # Stub health_run_all for local health path
  health_run_all() { echo "health_run_all $*"; }
  export -f health_run_all

  # Stub logs_tail / logs_download for local logs path
  logs_tail() { echo "logs_tail $*"; }
  export -f logs_tail
  logs_download() { echo "logs_download $*"; }
  export -f logs_download

  # Stub SSH: record args and succeed
  ssh() { echo "ssh $*"; return 0; }
  export -f ssh

  # Stub build_ssh_opts to return a predictable, stable value
  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  export -f build_ssh_opts

  # Default env file (VPS_HOST set → remote mode)
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.com
VPS_USER=ubuntu
VPS_PORT=22
VPS_SSH_KEY=
VPS_DEPLOY_DIR=/home/ubuntu/strut
EOF

  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="prod"
  export CMD_SERVICES=""
  export CMD_JSON=""
  export DRY_RUN=false
}

teardown() {
  common_teardown
}

# ── should_dispatch_remote ────────────────────────────────────────────────────

@test "should_dispatch_remote: true when VPS_HOST set and not on VPS" {
  export VPS_HOST="vps.example.com"
  is_running_on_vps() { return 1; }
  export -f is_running_on_vps

  run should_dispatch_remote
  [ "$status" -eq 0 ]
}

@test "should_dispatch_remote: false when VPS_HOST empty" {
  export VPS_HOST=""
  run should_dispatch_remote
  [ "$status" -ne 0 ]
}

@test "should_dispatch_remote: false when is_running_on_vps" {
  export VPS_HOST="vps.example.com"
  is_running_on_vps() { return 0; }
  export -f is_running_on_vps

  run should_dispatch_remote
  [ "$status" -ne 0 ]
}

# ── cmd_status remote ─────────────────────────────────────────────────────────

@test "cmd_status: dispatches via SSH when VPS_HOST is set" {
  export VPS_HOST="vps.example.com"
  run cmd_status
  [ "$status" -eq 0 ]
  # Should call ssh (not local docker compose ps directly)
  [[ "$output" == *"ssh"* ]]
  # Should include the strut status call targeting the correct env
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"prod"* ]]
}

@test "cmd_status: runs locally when VPS_HOST is empty" {
  cat > "$TEST_TMP/.local.env" <<'EOF'
VPS_HOST=
EOF
  export CMD_ENV_FILE="$TEST_TMP/.local.env"
  export VPS_HOST=""

  run cmd_status
  [ "$status" -eq 0 ]
  # Local path: compose ps, no ssh
  [[ "$output" == *"COMPOSE"* ]]
  [[ "$output" == *"ps"* ]]
  [[ "$output" != *"ssh"* ]]
}

@test "cmd_status: prints local host/project info when running locally" {
  cat > "$TEST_TMP/.local.env" <<'EOF'
VPS_HOST=
EOF
  export CMD_ENV_FILE="$TEST_TMP/.local.env"
  export VPS_HOST=""

  run cmd_status
  [ "$status" -eq 0 ]
  # The "looking here" log message should appear
  [[ "$output" == *"local"* ]]
}

@test "cmd_status: runs locally when already on VPS" {
  export VPS_HOST="vps.example.com"
  is_running_on_vps() { return 0; }
  export -f is_running_on_vps

  run cmd_status
  [ "$status" -eq 0 ]
  # is_running_on_vps=true → local path (no ssh)
  [[ "$output" == *"COMPOSE"* ]]
  [[ "$output" != *"ssh"* ]]
}

@test "cmd_status: dry-run prints plan without executing" {
  export VPS_HOST="vps.example.com"
  export DRY_RUN=true

  # Track whether ssh was actually called
  ssh() { echo "SSH_CALLED $*"; return 0; }
  export -f ssh

  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  # Under dry-run, run_cmd prints the plan — ssh should NOT be executed
  [[ "$output" != *"SSH_CALLED"* ]]
}

@test "cmd_status: --services flag forwarded to remote" {
  export VPS_HOST="vps.example.com"
  export CMD_SERVICES="full"

  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"full"* ]]
}

@test "cmd_status: fails gracefully when env file missing" {
  export CMD_ENV_FILE="$TEST_TMP/nonexistent.env"
  run cmd_status
  [[ "$output" == *"not found"* ]] || [ "$status" -ne 0 ]
}

# ── cmd_health remote ─────────────────────────────────────────────────────────

@test "cmd_health: dispatches via SSH when VPS_HOST is set" {
  export VPS_HOST="vps.example.com"
  run cmd_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"health"* ]]
}

@test "cmd_health: --json flag forwarded to remote" {
  export VPS_HOST="vps.example.com"
  export CMD_JSON="--json"

  run cmd_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"--json"* ]]
}

@test "cmd_health: runs locally when VPS_HOST is empty" {
  cat > "$TEST_TMP/.local.env" <<'EOF'
VPS_HOST=
EOF
  export CMD_ENV_FILE="$TEST_TMP/.local.env"
  export VPS_HOST=""

  run cmd_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"health_run_all"* ]]
  [[ "$output" != *"ssh"* ]]
}

@test "cmd_health: runs locally when already on VPS" {
  export VPS_HOST="vps.example.com"
  is_running_on_vps() { return 0; }
  export -f is_running_on_vps

  run cmd_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"health_run_all"* ]]
  [[ "$output" != *"ssh"* ]]
}

@test "cmd_health: dry-run prints plan without executing" {
  export VPS_HOST="vps.example.com"
  export DRY_RUN=true

  ssh() { echo "SSH_CALLED $*"; return 0; }
  export -f ssh

  run cmd_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" != *"SSH_CALLED"* ]]
}

# ── cmd_logs remote ───────────────────────────────────────────────────────────

@test "cmd_logs: dispatches via SSH when VPS_HOST is set" {
  export VPS_HOST="vps.example.com"
  run cmd_logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"logs"* ]]
}

@test "cmd_logs: service arg forwarded to remote" {
  export VPS_HOST="vps.example.com"
  run cmd_logs api
  [ "$status" -eq 0 ]
  [[ "$output" == *"api"* ]]
}

@test "cmd_logs: --follow flag forwarded to remote" {
  export VPS_HOST="vps.example.com"
  run cmd_logs --follow
  [ "$status" -eq 0 ]
  [[ "$output" == *"--follow"* ]]
}

@test "cmd_logs: --follow adds --tty to SSH options" {
  export VPS_HOST="vps.example.com"

  # Capture the build_ssh_opts call args to verify --tty was passed
  local tty_called=false
  build_ssh_opts() {
    for arg in "$@"; do
      [ "$arg" = "--tty" ] && echo "TTY_REQUESTED"
    done
    echo "-o StrictHostKeyChecking=no"
  }
  export -f build_ssh_opts

  run cmd_logs --follow
  [ "$status" -eq 0 ]
  [[ "$output" == *"TTY_REQUESTED"* ]]
}

@test "cmd_logs: --since flag forwarded to remote" {
  export VPS_HOST="vps.example.com"
  run cmd_logs --since 1h
  [ "$status" -eq 0 ]
  [[ "$output" == *"1h"* ]]
}

@test "cmd_logs: runs locally when VPS_HOST is empty" {
  cat > "$TEST_TMP/.local.env" <<'EOF'
VPS_HOST=
EOF
  export CMD_ENV_FILE="$TEST_TMP/.local.env"
  export VPS_HOST=""

  run cmd_logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"logs_tail"* ]]
  [[ "$output" != *"ssh"* ]]
}

@test "cmd_logs: runs locally when already on VPS" {
  export VPS_HOST="vps.example.com"
  is_running_on_vps() { return 0; }
  export -f is_running_on_vps

  run cmd_logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"logs_tail"* ]]
  [[ "$output" != *"ssh"* ]]
}

# ── cmd_logs_download remote ──────────────────────────────────────────────────

@test "cmd_logs_download: dispatches via SSH when VPS_HOST is set" {
  export VPS_HOST="vps.example.com"
  run cmd_logs_download
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"logs:download"* ]]
}

@test "cmd_logs_download: --since forwarded to remote" {
  export VPS_HOST="vps.example.com"
  run cmd_logs_download --since 48h
  [ "$status" -eq 0 ]
  [[ "$output" == *"48h"* ]]
}

@test "cmd_logs_download: default --since 24h forwarded to remote" {
  export VPS_HOST="vps.example.com"
  run cmd_logs_download
  [ "$status" -eq 0 ]
  [[ "$output" == *"24h"* ]]
}

@test "cmd_logs_download: runs locally when VPS_HOST is empty" {
  cat > "$TEST_TMP/.local.env" <<'EOF'
VPS_HOST=
EOF
  export CMD_ENV_FILE="$TEST_TMP/.local.env"
  export VPS_HOST=""

  run cmd_logs_download
  [ "$status" -eq 0 ]
  [[ "$output" == *"logs_download"* ]]
  [[ "$output" != *"ssh"* ]]
}
