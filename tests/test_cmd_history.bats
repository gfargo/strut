#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_history.bats — Tests for the history command
# ==================================================
# Run:  bats tests/test_cmd_history.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/history.sh"
  source "$CLI_ROOT/lib/cmd_history.sh"

  export LIB="$CLI_ROOT/lib"

  mkdir -p "$TEST_TMP/stacks/test-stack"
  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
}

teardown() { common_teardown; }

_set_history_ctx() {
  local env_file="$1"
  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$env_file"
  export CMD_ENV_NAME="test"
  export DRY_RUN=false
}

@test "cmd_history: dispatches remotely for a VPS-mapped stack" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.internal
EOF

  should_dispatch_remote() { return 0; }
  run_remote_strut() { echo "run_remote_strut $*"; }
  export -f should_dispatch_remote run_remote_strut

  _set_history_ctx "$TEST_TMP/.test.env"

  run cmd_history
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_remote_strut test-stack test history --limit 10"* ]]
}

@test "cmd_history: --json flag is forwarded to the remote dispatch" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.internal
EOF

  should_dispatch_remote() { return 0; }
  run_remote_strut() { echo "run_remote_strut $*"; }
  export -f should_dispatch_remote run_remote_strut

  _set_history_ctx "$TEST_TMP/.test.env"

  run cmd_history --json --limit 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"history --limit 5 --json"* ]]
}

@test "cmd_history: reads local history for a non-VPS stack" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  history_record "$TEST_TMP/stacks/test-stack" "deploy" "success" "env=test"

  _set_history_ctx ""

  run cmd_history
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"success"* ]]
}

@test "cmd_history: reports no history for a stack that's never deployed" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  _set_history_ctx ""

  run cmd_history
  [ "$status" -eq 0 ]
  [[ "$output" == *"No history recorded yet"* ]]
}

@test "cmd_history: --json emits parseable JSON for the local path" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  history_record "$TEST_TMP/stacks/test-stack" "release" "success" "env=test"

  _set_history_ctx ""

  run cmd_history --json
  [ "$status" -eq 0 ]
  if command -v jq &>/dev/null; then
    echo "$output" > "$TEST_TMP/out.json"
    run jq -e 'length == 1' "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
  fi
}
