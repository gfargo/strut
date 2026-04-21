#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_remote.bats — Smoke tests for cmd_shell / cmd_exec
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/cmd_remote.sh"

  # Stub ssh so nothing tries to connect out
  ssh() { echo "ssh $*"; return 0; }
  export -f ssh
  # Also stub exec to prevent cmd_shell from replacing the test process
  exec() { echo "exec $*"; return 0; }
  export -f exec

  # build_ssh_opts comes from utils.sh — no need to stub
  # validate_env_file comes from utils.sh

  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=example.com
VPS_USER=ubuntu
EOF

  export CMD_STACK="test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="test"
}

teardown() {
  common_teardown
}

@test "cmd_exec: fails when no command given" {
  run cmd_exec
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_exec: invokes ssh with command when given" {
  run cmd_exec "uptime"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"uptime"* ]]
}

@test "cmd_exec: fails when env file missing VPS_HOST" {
  cat > "$TEST_TMP/.bad.env" <<'EOF'
# no VPS_HOST
EOF
  export CMD_ENV_FILE="$TEST_TMP/.bad.env"
  run cmd_exec "hostname"
  [ "$status" -ne 0 ]
}

@test "cmd_exec: passes through multi-word command" {
  run cmd_exec "ls" "-la" "/tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ls"* ]]
  [[ "$output" == *"-la"* ]]
}

@test "cmd_shell: reads VPS_HOST and issues ssh" {
  run cmd_shell
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connecting"* ]] || [[ "$output" == *"ssh"* ]] || [[ "$output" == *"exec"* ]]
}

@test "cmd_shell: fails when env file missing VPS_HOST" {
  cat > "$TEST_TMP/.bad.env" <<'EOF'
# no VPS_HOST
EOF
  export CMD_ENV_FILE="$TEST_TMP/.bad.env"
  run cmd_shell
  [ "$status" -ne 0 ]
}
