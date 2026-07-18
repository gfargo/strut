#!/usr/bin/env bats
# ==================================================
# tests/test_deploy_up_failure.bats — strut#374 regression
# ==================================================
# A failed `compose up -d` used to be swallowed: deploy_stack fell through
# to the success banner/notify_event/history-success path even though the
# previous containers were already stopped and the new ones never started.
# This is especially dangerous through cmd_deploy's dispatch, which calls
# `deploy_stack ... || _deploy_rc=$?` — putting the whole call on the left
# side of `||` suppresses errexit for its entire call tree (POSIX/bash
# semantics), so nothing but an EXPLICIT check on the up -d exit status
# catches the failure.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_docker

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/deploy.sh"
  source "$CLI_ROOT/lib/cmd_deploy.sh"

  registry_login() { echo "REGISTRY_LOGIN_CALLED"; }
  docker_pull_stack() { echo "DOCKER_PULL_CALLED: $*"; }
  docker_require_images() { return 0; }
  rollback_save_snapshot() { :; }
  export_volume_paths() { :; }
  fire_hook() { return 0; }
  fire_hook_or_warn() { :; }
  fire_first_run_hook() { :; }
  maybe_apply_db_schema() { :; }
  notify_event() { echo "notify_event $*" >> "$TEST_TMP/notify_calls"; }
  print_banner() { :; }
  require_cmd() { :; }
  is_running_on_vps() { return 0; }
  cmd_validate() { return 0; }
  diff_warn_env_divergence() { return 0; }
  # Lock stubs — lock.sh not sourced in this unit test
  lock_acquire_local() { echo "test-nonce"; return 0; }
  lock_release_local() { return 0; }
  lock_is_stale_local() { return 1; }
  lock_force_break_local() { return 0; }
  export -f registry_login docker_pull_stack docker_require_images \
            rollback_save_snapshot export_volume_paths fire_hook \
            fire_hook_or_warn fire_first_run_hook maybe_apply_db_schema \
            notify_event print_banner require_cmd is_running_on_vps \
            cmd_validate diff_warn_env_divergence lock_acquire_local \
            lock_release_local lock_is_stale_local lock_force_break_local

  # Fake `docker` — `compose up -d --remove-orphans` is the one call this
  # suite makes fail; everything else (version check, down, ps -a collision
  # probe) succeeds.
  docker() {
    if [ "$1" = "compose" ]; then
      case " $* " in
        *" up -d --remove-orphans "*) return "${DOCKER_UP_EXIT:-0}" ;;
        *) return 0 ;;
      esac
    fi
    return 0
  }
  export -f docker
  export DOCKER_UP_EXIT=1

  mkdir -p "$TEST_TMP/stacks/hub"
  cat > "$TEST_TMP/stacks/hub/docker-compose.yml" <<'EOF'
services:
  app:
    image: hub-app
EOF
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=none
EOF
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
EOF

  # LIB must point at the real repo (history.sh lives there) — capture it
  # before CLI_ROOT is repointed at the test fixture dir below.
  export LIB="$CLI_ROOT/lib"
  export CLI_ROOT="$TEST_TMP"
  export DRY_RUN="false"
  export PRE_DEPLOY_VALIDATE="false"
  export SKIP_VALIDATION="false"
  : > "$TEST_TMP/notify_calls"
}

teardown() { common_teardown; }

@test "deploy_stack: compose up failure returns non-zero instead of reaching the success banner" {
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -ne 0 ]
  [[ "$output" != *"Deploy complete"* ]]
  [[ "$output" == *"compose up failed"* ]]
}

@test "deploy_stack: compose up failure fires deploy.failed, not deploy.success" {
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -ne 0 ]
  run cat "$TEST_TMP/notify_calls"
  [[ "$output" == *"deploy.failed"* ]]
  [[ "$output" != *"deploy.success"* ]]
}

@test "deploy_stack: compose up succeeding still reaches the success banner and fires deploy.success" {
  export DOCKER_UP_EXIT=0
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deploy complete"* ]]
  run cat "$TEST_TMP/notify_calls"
  [[ "$output" == *"deploy.success"* ]]
}

# The actual reported bug: cmd_deploy dispatches via `deploy_stack ... ||
# _deploy_rc=$?`, which suppresses errexit through the whole call tree. Only
# an explicit check inside deploy_stack (not ambient set -e) catches this.

@test "cmd_deploy: compose up failure propagates through the || _deploy_rc=\$? dispatch and records failed history" {
  mkdir -p "$TEST_TMP/stacks/hub"
  export CMD_STACK="hub"
  export CMD_STACK_DIR="$TEST_TMP/stacks/hub"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export CMD_ENV_NAME="prod"
  export CMD_SERVICES=""
  export CMD_JSON=""

  run cmd_deploy
  [ "$status" -ne 0 ]

  local hist_file="$TEST_TMP/stacks/hub/.deploy-history.jsonl"
  [ -f "$hist_file" ]
  run cat "$hist_file"
  [[ "$output" == *'"action":"deploy"'* ]]
  [[ "$output" == *'"outcome":"failed"'* ]]
}
