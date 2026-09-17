#!/usr/bin/env bats
# ==================================================
# tests/test_deploy_required_host_paths.bats — REQUIRED_HOST_PATHS guard
# ==================================================
# Covers _deploy_guard_required_host_paths: aborts a deploy BEFORE the
# down/up teardown if a services.conf-declared host path (a udev device
# symlink, most commonly) is missing, instead of tearing down a working
# stack and then failing to bring it back — the exact shape that removed
# watch's octoprint-ender3 container on 2026-08-24 (life-automation-infra
# 2026-09-17-octoprint-boot-restore-gap devlog).

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
}

teardown() {
  common_teardown
}

_load_deploy() {
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/deploy.sh"
  error() { echo "ERROR: $*"; }
}

@test "_deploy_guard_required_host_paths: unset REQUIRED_HOST_PATHS is a no-op" {
  _load_deploy
  unset REQUIRED_HOST_PATHS

  run _deploy_guard_required_host_paths
  [ "$status" -eq 0 ]
}

@test "_deploy_guard_required_host_paths: empty REQUIRED_HOST_PATHS is a no-op" {
  _load_deploy
  REQUIRED_HOST_PATHS=""

  run _deploy_guard_required_host_paths
  [ "$status" -eq 0 ]
}

@test "_deploy_guard_required_host_paths: all declared paths present — passes" {
  _load_deploy
  local dev1="$TEST_TMP/3dprinter"
  local dev2="$TEST_TMP/webcam0"
  touch "$dev1" "$dev2"
  REQUIRED_HOST_PATHS="$dev1 $dev2"

  run _deploy_guard_required_host_paths
  [ "$status" -eq 0 ]
}

@test "_deploy_guard_required_host_paths: a missing path aborts with diagnostics" {
  _load_deploy
  local missing="$TEST_TMP/3dprinter"
  REQUIRED_HOST_PATHS="$missing"

  run _deploy_guard_required_host_paths
  [ "$status" -eq 1 ]
  [[ "$output" == *"$missing"* ]]
  [[ "$output" == *"REQUIRED_HOST_PATHS"* ]]
}

@test "_deploy_guard_required_host_paths: lists every missing path, not just the first" {
  _load_deploy
  local present="$TEST_TMP/present"
  local missing1="$TEST_TMP/missing1"
  local missing2="$TEST_TMP/missing2"
  touch "$present"
  REQUIRED_HOST_PATHS="$present $missing1 $missing2"

  run _deploy_guard_required_host_paths
  [ "$status" -eq 1 ]
  [[ "$output" == *"$missing1"* ]]
  [[ "$output" == *"$missing2"* ]]
  [[ "$output" != *"$present"* ]]
}

@test "_deploy_guard_required_host_paths: accepts a directory, not just a file" {
  _load_deploy
  local dir="$TEST_TMP/some-dir"
  mkdir -p "$dir"
  REQUIRED_HOST_PATHS="$dir"

  run _deploy_guard_required_host_paths
  [ "$status" -eq 0 ]
}

# ── Full deploy_stack integration ──────────────────────────────────────────
# Same harness as test_deploy_up_failure.bats: proves the guard actually
# blocks a real deploy_stack call before `compose down` ever runs, not just
# that the standalone function returns non-zero in isolation.

setup_deploy_stack_harness() {
  load_docker

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/deploy.sh"

  registry_login() { echo "REGISTRY_LOGIN_CALLED"; }
  docker_pull_stack() { echo "DOCKER_PULL_CALLED: $*"; }
  docker_require_images() { return 0; }
  rollback_save_snapshot() { :; }
  export_volume_paths() { :; }
  fire_hook() { return 0; }
  fire_hook_or_warn() { :; }
  fire_first_run_hook() { :; }
  maybe_apply_db_schema() { :; }
  _bg_wait_healthy() { return 0; }
  notify_event() { echo "notify_event $*" >> "$TEST_TMP/notify_calls"; }
  print_banner() { :; }
  require_cmd() { :; }
  is_running_on_vps() { return 0; }
  cmd_validate() { return 0; }
  diff_warn_env_divergence() { return 0; }
  lock_acquire_local() { echo "test-nonce"; return 0; }
  lock_release_local() { return 0; }
  lock_is_stale_local() { return 1; }
  lock_force_break_local() { return 0; }
  export -f registry_login docker_pull_stack docker_require_images \
            rollback_save_snapshot export_volume_paths fire_hook \
            fire_hook_or_warn fire_first_run_hook maybe_apply_db_schema \
            _bg_wait_healthy \
            notify_event print_banner require_cmd is_running_on_vps \
            cmd_validate diff_warn_env_divergence lock_acquire_local \
            lock_release_local lock_is_stale_local lock_force_break_local

  # `docker compose down` must never be observed by this suite — if it is,
  # the guard didn't fire before teardown.
  docker() {
    if [ "$1" = "compose" ]; then
      case " $* " in
        *" down "*) echo "COMPOSE_DOWN_CALLED" >> "$TEST_TMP/docker_calls"; return 0 ;;
        *) return 0 ;;
      esac
    fi
    return 0
  }
  export -f docker

  mkdir -p "$TEST_TMP/stacks/octoprint-ender3"
  cat > "$TEST_TMP/stacks/octoprint-ender3/docker-compose.yml" <<'EOF'
services:
  octoprint-ender3:
    image: octoprint/octoprint:latest
    devices:
      - /dev/3dprinter:/dev/ttyACM0
EOF
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
EOF

  export LIB="$CLI_ROOT/lib"
  export CLI_ROOT="$TEST_TMP"
  export DRY_RUN="false"
  export PRE_DEPLOY_VALIDATE="false"
  export SKIP_VALIDATION="false"
  : > "$TEST_TMP/notify_calls"
  : > "$TEST_TMP/docker_calls"
}

@test "deploy_stack: missing REQUIRED_HOST_PATHS aborts before compose down ever runs" {
  setup_deploy_stack_harness
  cat > "$TEST_TMP/stacks/octoprint-ender3/services.conf" <<EOF
BUILD_MODE=none
REQUIRED_HOST_PATHS=$TEST_TMP/dev-3dprinter
EOF

  run deploy_stack "octoprint-ender3" "$TEST_TMP/.prod.env" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"REQUIRED_HOST_PATHS"* ]]
  [[ "$output" == *"dev-3dprinter"* ]]

  run cat "$TEST_TMP/docker_calls"
  [[ "$output" != *"COMPOSE_DOWN_CALLED"* ]]
}

@test "deploy_stack: present REQUIRED_HOST_PATHS proceeds through to compose down/up" {
  setup_deploy_stack_harness
  local dev="$TEST_TMP/dev-3dprinter"
  touch "$dev"
  cat > "$TEST_TMP/stacks/octoprint-ender3/services.conf" <<EOF
BUILD_MODE=none
REQUIRED_HOST_PATHS=$dev
EOF

  run deploy_stack "octoprint-ender3" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]

  run cat "$TEST_TMP/docker_calls"
  [[ "$output" == *"COMPOSE_DOWN_CALLED"* ]]
}
