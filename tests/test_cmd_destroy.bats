#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_destroy.bats — Tests for the destroy command
# ==================================================
# Run:  bats tests/test_cmd_destroy.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/hooks.sh"
  source "$CLI_ROOT/lib/cmd_destroy.sh"

  # LIB must point at the real repo (deploy_blue_green.sh lives there) —
  # capture it before CLI_ROOT is repointed at the test fixture dir below.
  export LIB="$CLI_ROOT/lib"

  # Create a minimal test stack
  mkdir -p "$TEST_TMP/stacks/test-stack/hooks"
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

# Helper: set CMD_* context for cmd_destroy
_set_destroy_ctx() {
  local env_file="$1"
  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$env_file"
  export CMD_ENV_NAME="test"
  export CMD_SERVICES=""
  export CMD_JSON=""
}

@test "cmd_destroy: calls compose down with --remove-orphans and --volumes" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy
  [ "$status" -eq 0 ]
  [[ "$output" == *"destroyed"* ]]
  [[ "$output" == *"--remove-orphans"* ]]
  [[ "$output" == *"--volumes"* ]]
}

@test "cmd_destroy: --timeout flag is accepted" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy --timeout 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"--timeout 30"* ]]
}

@test "cmd_destroy: dry-run shows execution plan and does not remove marker" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  echo "initialized=2024-01-01T00:00:00Z" > "$TEST_TMP/stacks/test-stack/.strut-initialized"
  export DRY_RUN=true
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"pre_destroy"* ]]
  [[ "$output" == *"post_destroy"* ]]
  [ -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
}

@test "cmd_destroy: fails when env file missing" {
  _set_destroy_ctx "$TEST_TMP/nonexistent.env"
  run cmd_destroy
  [ "$status" -ne 0 ] || [[ "$output" == *"not found"* ]]
}

@test "cmd_destroy: targets the blue-green active project when one is deployed" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  echo "active_color=green" > "$TEST_TMP/stacks/test-stack/.bluegreen.test"
  echo "active_project=test-stack-test-green" >> "$TEST_TMP/stacks/test-stack/.bluegreen.test"

  resolve_compose_cmd() { echo "echo PROJECT=$4"; }
  export -f resolve_compose_cmd
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJECT=test-stack-test-green"* ]]
}

@test "cmd_destroy: removes first-run marker on success" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  echo "initialized=2024-01-01T00:00:00Z" > "$TEST_TMP/stacks/test-stack/.strut-initialized"
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
}

@test "cmd_destroy: pre_destroy hook failure aborts before down and marker removal" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  echo "initialized=2024-01-01T00:00:00Z" > "$TEST_TMP/stacks/test-stack/.strut-initialized"
  cat > "$TEST_TMP/stacks/test-stack/hooks/pre_destroy.sh" <<'EOF'
#!/bin/bash
echo "pre_destroy hook ran"
exit 1
EOF
  chmod +x "$TEST_TMP/stacks/test-stack/hooks/pre_destroy.sh"
  resolve_compose_cmd() { echo "echo COMPOSE DOWN"; }
  export -f resolve_compose_cmd
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy
  [ "$status" -ne 0 ]
  [[ "$output" == *"pre_destroy hook ran"* ]]
  [[ "$output" != *"COMPOSE DOWN"* ]]
  # marker must survive an aborted destroy
  [ -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
}

@test "cmd_destroy: post_destroy hook failure warns but marker is still removed" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  echo "initialized=2024-01-01T00:00:00Z" > "$TEST_TMP/stacks/test-stack/.strut-initialized"
  cat > "$TEST_TMP/stacks/test-stack/hooks/post_destroy.sh" <<'EOF'
#!/bin/bash
echo "post_destroy hook ran"
exit 1
EOF
  chmod +x "$TEST_TMP/stacks/test-stack/hooks/post_destroy.sh"
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy
  [ "$status" -eq 0 ]
  [[ "$output" == *"post_destroy hook ran"* ]]
  [[ "$output" == *"failed (continuing)"* ]]
  [ ! -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
}

@test "cmd_destroy: hook ordering — pre_destroy before down, post_destroy and marker removal after" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  echo "initialized=2024-01-01T00:00:00Z" > "$TEST_TMP/stacks/test-stack/.strut-initialized"
  local order_log="$TEST_TMP/order.log"
  cat > "$TEST_TMP/stacks/test-stack/hooks/pre_destroy.sh" <<EOF
#!/bin/bash
echo "pre_destroy" >> "$order_log"
EOF
  cat > "$TEST_TMP/stacks/test-stack/hooks/post_destroy.sh" <<EOF
#!/bin/bash
echo "post_destroy" >> "$order_log"
EOF
  chmod +x "$TEST_TMP/stacks/test-stack/hooks/pre_destroy.sh" "$TEST_TMP/stacks/test-stack/hooks/post_destroy.sh"
  cat > "$TEST_TMP/fake-compose.sh" <<EOF
#!/bin/bash
echo "down" >> "$order_log"
EOF
  chmod +x "$TEST_TMP/fake-compose.sh"
  resolve_compose_cmd() { echo "$TEST_TMP/fake-compose.sh"; }
  export -f resolve_compose_cmd
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy
  [ "$status" -eq 0 ]
  [ "$(cat "$order_log" | tr '\n' ',')" = "pre_destroy,down,post_destroy," ]
  [ ! -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
}

# strut#384-class bug: destroy must forward to the SSH'd remote invocation
# and not silently drop --timeout when VPS-mapped.

@test "cmd_destroy: remote dispatch forwards --timeout to the SSH command" {
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
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy --timeout 45
  [ "$status" -eq 0 ]
  [[ "$output" == *"--timeout 45"* ]]
  [[ "$output" == *"destroy"* ]]
}

@test "cmd_destroy: remote dry-run plan shows --timeout and does not execute" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.com
EOF
  export DRY_RUN=true
  is_running_on_vps() { return 1; }
  export -f is_running_on_vps
  resolve_deploy_dir() { echo "/home/ubuntu/strut"; }
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  export -f resolve_deploy_dir build_ssh_opts
  _set_destroy_ctx "$TEST_TMP/.test.env"

  run cmd_destroy --timeout 45
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"--timeout 45"* ]]
}
