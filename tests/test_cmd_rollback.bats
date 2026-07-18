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
  # Real deploy_blue_green.sh (not a stub) so _bg_state_file/_bg_active_project
  # are genuinely defined — mirrors the entrypoint, which always sources this
  # before cmd_rollback.sh. Tests that stub bg_rollback_stack must do so
  # AFTER this source call, or cmd_rollback.sh's own `declare -F
  # bg_rollback_stack || source ...` guard will see the stub, skip sourcing,
  # and leave _bg_state_file undefined.
  source "$CLI_ROOT/lib/deploy_blue_green.sh"
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

  echo '{"timestamp":"2026-07-05T00:00:00Z","service_count":1,"services":{"web":{"image":"nginx:latest"}}}' > "$TEST_TMP/snapshot.json"

  # References $TEST_TMP (a global from common.bash), not a local var — a
  # `local snapshot_file` here would be shadowed by cmd_rollback's own
  # same-named local via bash's dynamic scoping, echoing empty instead.
  rollback_get_latest_snapshot() { echo "$TEST_TMP/snapshot.json"; }
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
  echo '{"timestamp":"2026-07-05T00:00:00Z","service_count":1,"services":{"web":{"image":"nginx:latest"}}}' > "$TEST_TMP/snapshot.json"

  should_dispatch_remote() { return 1; }
  # References $TEST_TMP (a global from common.bash), not a local var — a
  # `local snapshot_file` here would be shadowed by cmd_rollback's own
  # same-named local via bash's dynamic scoping, echoing empty instead.
  rollback_get_latest_snapshot() { echo "rollback_get_latest_snapshot $*" >&2; echo "$TEST_TMP/snapshot.json"; }
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

@test "cmd_rollback: records a history entry on a successful restore" {
  echo '{"timestamp":"2026-07-05T00:00:00Z","service_count":1,"services":{"web":{"image":"nginx:latest"}}}' > "$TEST_TMP/snapshot.json"

  should_dispatch_remote() { return 1; }
  rollback_get_latest_snapshot() { echo "$TEST_TMP/snapshot.json"; }
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  rollback_restore_snapshot() { echo "rollback_restore_snapshot $*"; }
  export -f should_dispatch_remote rollback_get_latest_snapshot resolve_compose_cmd rollback_restore_snapshot

  _set_rollback_ctx ""

  run cmd_rollback
  [ "$status" -eq 0 ]

  local hist_file="$TEST_TMP/stacks/test-stack/.deploy-history.jsonl"
  [ -f "$hist_file" ]
  run cat "$hist_file"
  [[ "$output" == *'"action":"rollback"'* ]]
  [[ "$output" == *'"outcome":"success"'* ]]
}

# ── Blue-green dispatch (strut#375) ──────────────────────────────────────────
# cmd_rollback used to check only the legacy per-stack `.bluegreen` file,
# ignoring env — a stack blue-green-deployed under a different env than the
# one being rolled back could misdetect (or miss) blue-green mode.

@test "cmd_rollback: per-env blue-green state file dispatches to bg_rollback_stack" {
  should_dispatch_remote() { return 1; }
  bg_rollback_stack() { echo "bg_rollback_stack $*"; return 0; }
  export -f should_dispatch_remote bg_rollback_stack

  echo "active_color=blue" > "$TEST_TMP/stacks/test-stack/.bluegreen.test"

  _set_rollback_ctx ""

  run cmd_rollback
  [ "$status" -eq 0 ]
  [[ "$output" == *"bg_rollback_stack test-stack"* ]]
}

@test "cmd_rollback: legacy per-stack state file (pre-migration) still dispatches to bg_rollback_stack" {
  should_dispatch_remote() { return 1; }
  bg_rollback_stack() { echo "bg_rollback_stack $*"; return 0; }
  export -f should_dispatch_remote bg_rollback_stack

  echo "active_color=blue" > "$TEST_TMP/stacks/test-stack/.bluegreen"

  _set_rollback_ctx ""

  run cmd_rollback
  [ "$status" -eq 0 ]
  [[ "$output" == *"bg_rollback_stack test-stack"* ]]
}

@test "cmd_rollback: no blue-green state file uses the standard restore path" {
  should_dispatch_remote() { return 1; }
  bg_rollback_stack() { echo "SHOULD_NOT_BE_CALLED"; return 0; }
  rollback_get_latest_snapshot() { echo ""; }
  export -f should_dispatch_remote bg_rollback_stack rollback_get_latest_snapshot

  _set_rollback_ctx ""

  run cmd_rollback
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}
