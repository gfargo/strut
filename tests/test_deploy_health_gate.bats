#!/usr/bin/env bats
# ==================================================
# tests/test_deploy_health_gate.bats — strut#407 (item 1)
# ==================================================
# The standard deploy path used to burn a fixed 60s dot-sleep after
# `compose up -d` and then print the success banner unconditionally — a
# crash-looping stack still "deployed successfully". deploy_stack now
# health-gates via _bg_wait_healthy (the blue-green poll loop, label
# "stack"): on timeout/crash-loop it fires on_health_fail + deploy.failed
# and returns non-zero instead of reaching the banner.
#
# The wiring is tested here with _bg_wait_healthy stubbed (recording its
# args); the real poll loop's semantics are covered by the blue-green unit
# + integration suites. The last two tests exercise the REAL loop just for
# the new label parameter (default "green" preserved; "stack" honored).

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_docker

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/deploy.sh"

  registry_login() { echo "REGISTRY_LOGIN_CALLED"; }
  docker_pull_stack() { echo "DOCKER_PULL_CALLED: $*"; }
  docker_require_images() { return 0; }
  rollback_save_snapshot() { :; }
  export_volume_paths() { :; }
  fire_hook() { return 0; }
  fire_hook_or_warn() { echo "hook_or_warn $* HEALTH_STATUS=${HEALTH_STATUS:-}" >> "$TEST_TMP/hook_calls"; }
  fire_first_run_hook() { :; }
  maybe_apply_db_schema() { :; }
  # Health gate stub — records args, exits per GATE_EXIT so tests can
  # drive both outcomes. Predefining it means deploy_stack's lazy
  # `declare -F || source` keeps the stub instead of the real loop.
  _bg_wait_healthy() { echo "wait_healthy|$*" >> "$TEST_TMP/gate_calls"; return "${GATE_EXIT:-0}"; }
  notify_event() { echo "notify_event $*" >> "$TEST_TMP/notify_calls"; }
  print_banner() { :; }
  require_cmd() { :; }
  is_running_on_vps() { return 0; }
  cmd_validate() { return 0; }
  diff_warn_env_divergence() { return 0; }
  export -f registry_login docker_pull_stack docker_require_images \
            rollback_save_snapshot export_volume_paths fire_hook \
            fire_hook_or_warn fire_first_run_hook maybe_apply_db_schema \
            _bg_wait_healthy notify_event print_banner require_cmd \
            is_running_on_vps cmd_validate diff_warn_env_divergence

  # Fake `docker` — every compose call succeeds; the gate stub is the only
  # thing that decides this suite's failures.
  docker() { return 0; }
  export -f docker

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

  export LIB="$CLI_ROOT/lib"
  export CLI_ROOT="$TEST_TMP"
  export DRY_RUN="false"
  export PRE_DEPLOY_VALIDATE="false"
  export SKIP_VALIDATION="false"
  : > "$TEST_TMP/notify_calls"
  : > "$TEST_TMP/gate_calls"
  : > "$TEST_TMP/hook_calls"
}

teardown() { common_teardown; }

@test "deploy_stack: healthy gate reaches the success banner and fires deploy.success" {
  export GATE_EXIT=0
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deploy complete"* ]]
  run cat "$TEST_TMP/notify_calls"
  [[ "$output" == *"deploy.success"* ]]
}

@test "deploy_stack: gate is called with the stack label and 60s default timeout" {
  export GATE_EXIT=0
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  run cat "$TEST_TMP/gate_calls"
  [[ "$output" == *"|$TEST_TMP/stacks/hub "* ]]
  [[ "$output" == *" 60 stack"* ]]
}

@test "deploy_stack: DEPLOY_HEALTH_TIMEOUT overrides the gate timeout" {
  export GATE_EXIT=0
  export DEPLOY_HEALTH_TIMEOUT=90
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  run cat "$TEST_TMP/gate_calls"
  [[ "$output" == *" 90 stack"* ]]
}

@test "deploy_stack: gate failure returns non-zero instead of reaching the success banner" {
  export GATE_EXIT=1
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -ne 0 ]
  [[ "$output" != *"Deploy complete"* ]]
  [[ "$output" == *"did not become healthy"* ]]
}

@test "deploy_stack: gate failure fires deploy.failed (reason=health_gate_failed), not deploy.success" {
  export GATE_EXIT=1
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -ne 0 ]
  run cat "$TEST_TMP/notify_calls"
  [[ "$output" == *"deploy.failed"* ]]
  [[ "$output" == *"reason=health_gate_failed"* ]]
  [[ "$output" != *"deploy.success"* ]]
}

@test "deploy_stack: gate failure fires the on_health_fail hook with HEALTH_STATUS exported" {
  export GATE_EXIT=2
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -ne 0 ]
  run cat "$TEST_TMP/hook_calls"
  [[ "$output" == *"on_health_fail"* ]]
  [[ "$output" == *"HEALTH_STATUS=2"* ]]
}

@test "deploy_stack: DEPLOY_SKIP_HEALTH_GATE=true skips the gate entirely" {
  export GATE_EXIT=1
  export DEPLOY_SKIP_HEALTH_GATE=true
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deploy complete"* ]]
  [[ "$output" == *"Health gate skipped"* ]]
  # Gate stub was never called
  run cat "$TEST_TMP/gate_calls"
  [ -z "$output" ]
}

@test "deploy_stack: DEPLOY_SKIP_HEALTH_GATE=1 also skips the gate" {
  export GATE_EXIT=1
  export DEPLOY_SKIP_HEALTH_GATE=1
  run deploy_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deploy complete"* ]]
}

# ── Real _bg_wait_healthy: label parameter ────────────────────────────────────

# Sources the real loop with its probes stubbed healthy so it returns after
# the consecutive-ok threshold. Zero interval keeps it instant (safe here
# because the probe always passes — the loop can't spin on a 0s interval).
_run_real_wait_healthy() {
  unset -f _bg_wait_healthy
  source "$LIB/deploy_blue_green.sh"
  health_check_project() { return 0; }
  _bg_any_container_restarted() { return 1; }
  ok()   { echo "OK: $*"; }
  log()  { echo "LOG: $*"; }
  warn() { echo "WARN: $*" >&2; }
  BLUE_GREEN_HEALTH_POLL_INTERVAL=0 _bg_wait_healthy "$TEST_TMP/stacks/hub" "docker compose" "compose.yml" 5 "$@"
}

@test "_bg_wait_healthy: default label stays 'green' for blue-green callers" {
  run _run_real_wait_healthy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Waiting for green health"* ]]
  [[ "$output" == *"green healthy"* ]]
}

@test "_bg_wait_healthy: 'stack' label is used in log output when passed" {
  run _run_real_wait_healthy "stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Waiting for stack health"* ]]
  [[ "$output" == *"stack healthy"* ]]
  [[ "$output" != *"green"* ]]
}

@test "_bg_wait_healthy: returns non-zero on timeout when health never passes" {
  run bash -c '
    source "'"$LIB"'/deploy_blue_green.sh"
    source "'"$CLI_ROOT"'/lib/health.sh"
    health_check_project() { return 1; }
    _bg_any_container_restarted() { return 1; }
    ok()   { echo "OK: $*"; }
    log()  { echo "LOG: $*"; }
    warn() { echo "WARN: $*" >&2; }
    export STRUT_HOME="'"$CLI_ROOT"'"
    BLUE_GREEN_HEALTH_POLL_INTERVAL=1 _bg_wait_healthy "'"$TEST_TMP/stacks/hub"'" "docker compose" "compose.yml" 2
  '
  [ "$status" -ne 0 ]
  [[ "$output" != *"healthy"* ]]
}
