#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_rollback.bats — Tests for the rollback command
# ==================================================
# Run:  bats tests/test_cmd_rollback.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/rollback.sh"
  source "$CLI_ROOT/lib/cmd_rollback.sh"

  export LIB="$CLI_ROOT/lib"

  mkdir -p "$TEST_TMP/stacks/test-stack"
  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
}

teardown() {
  common_teardown
}

_set_rollback_ctx() {
  local env_file="$1"
  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$env_file"
  export CMD_ENV_NAME="test"
  export CMD_SERVICES=""
  export CMD_JSON=""
  export DRY_RUN=false
}

@test "cmd_rollback: preserves dispatcher-resolved VPS_HOST (--host override) over env file value" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=primary-host.internal
EOF
  export VPS_HOST="standby-host.internal"

  local fixture_snapshot_file="$TEST_TMP/snapshot.json"
  echo '{"timestamp":"2026-07-05T00:00:00Z","service_count":1,"services":{"web":{"image":"nginx:latest"}}}' > "$fixture_snapshot_file"

  # Named distinctly from cmd_rollback's own `local snapshot_file` — bash's
  # dynamic scoping would otherwise resolve "$snapshot_file" inside this mock
  # to cmd_rollback's (unset) local instead of this fixture path.
  rollback_get_latest_snapshot() { echo "$fixture_snapshot_file"; }
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  rollback_restore_snapshot() { echo "rollback_restore_snapshot $*"; }
  # Force the local restore path — this test targets VPS_HOST preservation in
  # validate_env_file, not remote dispatch (covered separately).
  should_dispatch_remote() { return 1; }
  export -f rollback_get_latest_snapshot resolve_compose_cmd rollback_restore_snapshot should_dispatch_remote

  _set_rollback_ctx "$TEST_TMP/.test.env"

  (
    set +e
    cmd_rollback > "$TEST_TMP/rollback.out" 2>&1
    echo $? > "$TEST_TMP/rollback.status"
    echo "$VPS_HOST" > "$TEST_TMP/vps_host_after"
  )

  [ "$(cat "$TEST_TMP/rollback.status")" = "0" ]
  [ "$(cat "$TEST_TMP/vps_host_after")" = "standby-host.internal" ]
}

@test "cmd_rollback: dispatches restore remotely for a VPS stack" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.internal
EOF

  should_dispatch_remote() { return 0; }
  run_remote_strut() { echo "run_remote_strut $*"; }
  rollback_get_latest_snapshot() { echo "SHOULD_NOT_BE_CALLED"; }
  resolve_compose_cmd() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f should_dispatch_remote run_remote_strut rollback_get_latest_snapshot resolve_compose_cmd

  _set_rollback_ctx "$TEST_TMP/.test.env"

  run cmd_rollback
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_remote_strut test-stack test rollback"* ]]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

@test "cmd_rollback: dispatches --list remotely for a VPS stack" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.internal
EOF

  should_dispatch_remote() { return 0; }
  run_remote_strut() { echo "run_remote_strut $*"; }
  rollback_list_snapshots() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f should_dispatch_remote run_remote_strut rollback_list_snapshots

  _set_rollback_ctx "$TEST_TMP/.test.env"

  run cmd_rollback --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_remote_strut test-stack test rollback --list"* ]]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

@test "cmd_rollback: local restore looks up the env-filtered snapshot" {
  local fixture_snapshot_file="$TEST_TMP/snapshot.json"
  echo '{"timestamp":"2026-07-05T00:00:00Z","service_count":1,"services":{"web":{"image":"nginx:latest"}}}' > "$fixture_snapshot_file"

  should_dispatch_remote() { return 1; }
  rollback_get_latest_snapshot() { echo "rollback_get_latest_snapshot $*" >&2; echo "$fixture_snapshot_file"; }
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  rollback_restore_snapshot() { echo "rollback_restore_snapshot $*"; }
  export -f should_dispatch_remote rollback_get_latest_snapshot resolve_compose_cmd rollback_restore_snapshot

  _set_rollback_ctx ""

  run cmd_rollback
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollback_get_latest_snapshot test-stack test"* ]]
}

@test "cmd_rollback: no matching snapshot names the env in the error" {
  should_dispatch_remote() { return 1; }
  rollback_get_latest_snapshot() { echo ""; }
  export -f should_dispatch_remote rollback_get_latest_snapshot

  _set_rollback_ctx ""

  run cmd_rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *"No rollback snapshots found for stack: test-stack, env: test"* ]]
}
