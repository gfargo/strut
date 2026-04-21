#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_logs.bats — Smoke tests for cmd_logs / cmd_logs_download / cmd_logs_rotate
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/cmd_logs.sh"

  # Stubs
  logs_tail() { echo "logs_tail $*"; }
  export -f logs_tail
  logs_download() { echo "logs_download $*"; }
  export -f logs_download
  logs_rotate() { echo "logs_rotate $*"; }
  export -f logs_rotate
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd

  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF

  export CMD_STACK="test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="test"
  export CMD_SERVICES=""
}

teardown() {
  common_teardown
}

@test "_usage_logs: prints usage" {
  run _usage_logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"logs"* ]]
  [[ "$output" == *"--follow"* ]]
}

@test "cmd_logs: dispatches to logs_tail with no args" {
  run cmd_logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"logs_tail"* ]]
}

@test "cmd_logs: --follow flag passes through" {
  run cmd_logs --follow
  [ "$status" -eq 0 ]
  [[ "$output" == *"logs_tail"* ]]
  [[ "$output" == *"--follow"* ]]
}

@test "cmd_logs: -f short flag recognized" {
  run cmd_logs -f
  [ "$status" -eq 0 ]
  [[ "$output" == *"--follow"* ]]
}

@test "cmd_logs: positional service arg passed through" {
  run cmd_logs my-service
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-service"* ]]
}

@test "cmd_logs: warns when env file missing" {
  export CMD_ENV_FILE="$TEST_TMP/nonexistent.env"
  run cmd_logs
  [[ "$output" == *"not found"* ]] || [ "$status" -ne 0 ]
}

@test "cmd_logs_download: default --since 24h" {
  run cmd_logs_download
  [ "$status" -eq 0 ]
  [[ "$output" == *"logs_download"* ]]
  [[ "$output" == *"24h"* ]]
}

@test "cmd_logs_download: --since flag overrides" {
  run cmd_logs_download --since 1h
  [ "$status" -eq 0 ]
  [[ "$output" == *"1h"* ]]
}

@test "cmd_logs_download: --since=value form works" {
  run cmd_logs_download --since=30m
  [ "$status" -eq 0 ]
  [[ "$output" == *"30m"* ]]
}

@test "cmd_logs_rotate: default 7 days" {
  run cmd_logs_rotate
  [ "$status" -eq 0 ]
  [[ "$output" == *"logs_rotate"* ]]
  [[ "$output" == *"7"* ]]
}

@test "cmd_logs_rotate: custom days passed through" {
  run cmd_logs_rotate 14
  [ "$status" -eq 0 ]
  [[ "$output" == *"14"* ]]
}
