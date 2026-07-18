#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_stop.bats — Tests for the stop command
# ==================================================
# Run:  bats tests/test_cmd_stop.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/cmd_stop.sh"

  # LIB must point at the real repo (deploy_blue_green.sh lives there) —
  # capture it before CLI_ROOT is repointed at the test fixture dir below.
  export LIB="$CLI_ROOT/lib"

  # Create a minimal test stack
  mkdir -p "$TEST_TMP/stacks/test-stack"
  echo "services:" > "$TEST_TMP/stacks/test-stack/docker-compose.yml"
  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"

  # Stub out docker compose so we don't need a real Docker daemon
  docker() {
    echo "docker $*"
    return 0
  }
  export -f docker

  # Stub is_running_on_vps to return false (local mode)
  is_running_on_vps() { return 1; }
  export -f is_running_on_vps
}

teardown() {
  common_teardown
}

# Helper: set CMD_* context for cmd_stop
_set_stop_ctx() {
  local env_file="$1"
  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$env_file"
  export CMD_ENV_NAME="test"
  export CMD_SERVICES=""
  export CMD_JSON=""
}

@test "cmd_stop: calls compose down with --remove-orphans" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped"* ]]
}

@test "cmd_stop: --volumes flag is accepted" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop --volumes
  [ "$status" -eq 0 ]
}

@test "cmd_stop: --timeout flag is accepted" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop --timeout 30
  [ "$status" -eq 0 ]
}

@test "cmd_stop: dry-run shows execution plan" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  export DRY_RUN=true
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_stop: fails when env file missing" {
  _set_stop_ctx "$TEST_TMP/nonexistent.env"
  run cmd_stop
  [ "$status" -ne 0 ] || [[ "$output" == *"not found"* ]]
}

@test "cmd_stop: preserves dispatcher-resolved VPS_HOST (--host override) over env file value" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=primary-host.internal
EOF
  export DRY_RUN=true
  export VPS_HOST="standby-host.internal"
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"standby-host.internal"* ]]
  [[ "$output" != *"primary-host.internal"* ]]
}

# strut#384: stop used to always target the plain <stack>-<env> project,
# which blue-green deploys never use — after a blue-green deploy `stop`
# would down an empty project and report success while the active color
# kept serving.

@test "cmd_stop: targets the blue-green active project when one is deployed" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  echo "active_color=green" > "$TEST_TMP/stacks/test-stack/.bluegreen.test"
  echo "active_project=test-stack-test-green" >> "$TEST_TMP/stacks/test-stack/.bluegreen.test"

  resolve_compose_cmd() { echo "echo PROJECT=$4"; }
  export -f resolve_compose_cmd
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJECT=test-stack-test-green"* ]]
}

@test "cmd_stop: no blue-green state → resolve_compose_cmd gets an empty project override" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  resolve_compose_cmd() { echo "echo PROJECT=[$4]"; }
  export -f resolve_compose_cmd
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJECT=[]"* ]]
}

# strut#384: remote stop built its down_args (--volumes/--timeout) but never
# forwarded them to the SSH'd remote invocation — a VPS-mapped `stop
# --volumes` silently dropped both flags.

@test "cmd_stop: remote dispatch forwards --volumes and --timeout to the SSH command" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.com
EOF
  is_running_on_vps() { return 1; }
  export -f is_running_on_vps
  resolve_deploy_dir() { echo "/home/ubuntu/strut"; }
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  export -f resolve_deploy_dir build_ssh_opts
  ssh() { echo "ssh $*"; return 0; }
  export -f ssh
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop --volumes --timeout 45
  [ "$status" -eq 0 ]
  [[ "$output" == *"--volumes"* ]]
  [[ "$output" == *"--timeout 45"* ]]
}

@test "cmd_stop: remote dry-run plan shows --volumes and --timeout" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.com
EOF
  export DRY_RUN=true
  is_running_on_vps() { return 1; }
  export -f is_running_on_vps
  resolve_deploy_dir() { echo "/home/ubuntu/strut"; }
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  export -f resolve_deploy_dir build_ssh_opts
  _set_stop_ctx "$TEST_TMP/.test.env"

  run cmd_stop --volumes --timeout 45
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"--volumes"* ]]
  [[ "$output" == *"--timeout 45"* ]]
}
