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

  local snapshot_file="$TEST_TMP/snapshot.json"
  echo '{"timestamp":"2026-07-05T00:00:00Z","service_count":1,"services":{"web":{"image":"nginx:latest"}}}' > "$snapshot_file"

  rollback_get_latest_snapshot() { echo "$snapshot_file"; }
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  rollback_restore_snapshot() { echo "rollback_restore_snapshot $*"; }
  export -f rollback_get_latest_snapshot resolve_compose_cmd rollback_restore_snapshot

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
