#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_debug.bats — Smoke tests for cmd_debug dispatch
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/cmd_debug.sh"

  # Stub debug_* underlying functions
  debug_exec() { echo "debug_exec $*"; }
  debug_shell() { echo "debug_shell $*"; }
  debug_port_forward() { echo "debug_port_forward $*"; }
  debug_copy() { echo "debug_copy $*"; }
  debug_snapshot() { echo "debug_snapshot $*"; }
  debug_inspect_env() { echo "debug_inspect_env $*"; }
  debug_resource_usage() { echo "debug_resource_usage $*"; }
  export -f debug_exec debug_shell debug_port_forward debug_copy \
            debug_snapshot debug_inspect_env debug_resource_usage

  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF

  export CMD_STACK="test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="test"
}

teardown() {
  common_teardown
}

@test "cmd_debug: fails when no subcommand given" {
  run cmd_debug
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_debug: unknown subcommand fails with help" {
  run cmd_debug bogus api
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown debug command"* ]]
}

@test "cmd_debug: exec routes to debug_exec" {
  run cmd_debug exec my-service 'echo hello'
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug_exec"* ]]
  [[ "$output" == *"my-service"* ]]
}

@test "cmd_debug: exec without service fails" {
  run cmd_debug exec
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_debug: shell routes to debug_shell" {
  run cmd_debug shell my-service
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug_shell"* ]]
  [[ "$output" == *"my-service"* ]]
}

@test "cmd_debug: shell without service fails" {
  run cmd_debug shell
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_debug: port-forward accepts local:remote form" {
  run cmd_debug port-forward my-service 8080:80
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug_port_forward"* ]]
}

@test "cmd_debug: port-forward with invalid mapping fails" {
  run cmd_debug port-forward my-service not-a-port
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid port"* ]]
}

@test "cmd_debug: snapshot routes to debug_snapshot" {
  run cmd_debug snapshot my-service
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug_snapshot"* ]]
}

@test "cmd_debug: inspect-env routes to debug_inspect_env" {
  run cmd_debug inspect-env my-service
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug_inspect_env"* ]]
}

@test "cmd_debug: stats routes to debug_resource_usage" {
  run cmd_debug stats my-service
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug_resource_usage"* ]]
}

@test "cmd_debug: copy requires source and dest" {
  run cmd_debug copy my-service
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_debug: copy with source and dest routes to debug_copy" {
  run cmd_debug copy my-service /src /dest
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug_copy"* ]]
}
