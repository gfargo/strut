#!/usr/bin/env bats
# ==================================================
# tests/test_deploy_blue_green.bats — Blue-green deploy orchestration
# ==================================================
# Exercises the small composable helpers in lib/deploy_blue_green.sh and
# the top-level bg_deploy_stack orchestrator with every underlying action
# (docker compose, health, proxy swap, drain, notify) stubbed out.
#
# What we care about:
#   1. Color-picking is right (first deploy → blue; subsequent → flipped)
#   2. Project names are correct for both slots
#   3. State file round-trips
#   4. Happy path calls helpers in order: start → healthy → swap → drain → stop → write
#   5. Health failure path → teardown green, don't touch old color, exit non-zero
#   6. Dry-run returns before any side effects
#   7. Rollback flips active_color and brings the drained project back up
#   8. Proxy hook is sourced + invoked when BLUE_GREEN_PROXY_HOOK is set
#   9. Missing/broken hook file fails loudly

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Non-exiting overrides — keep tests alive when helpers call fail/ok/warn.
  source "$CLI_ROOT/lib/output.sh"
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  print_banner() { echo "BANNER: $*"; }

  # Side-effect-free stubs for everything the orchestrator depends on.
  require_cmd() { return 0; }
  extract_env_name() {
    # Cheap copy matching lib/utils.sh — tests use predictable names.
    local f; f="$(basename "$1")"
    case "$f" in
      .*.env)  local n="${f#.}"; echo "${n%.env}" ;;
      .env.*)  echo "${f#.env.}" ;;
      *)       echo "prod" ;;
    esac
  }
  export_volume_paths() { :; }
  _docker_sudo() { :; }
  registry_login() { echo "registry_login"; }
  rollback_save_snapshot() { echo "rollback_save_snapshot $*"; }
  fire_hook() { echo "fire_hook $*"; return 0; }
  fire_hook_or_warn() { echo "fire_hook_or_warn $*"; }
  notify_event() { echo "notify_event $*"; }
  cmd_validate() { return 0; }
  run_cmd() { echo "RUN: $*"; }
  export -f fail ok warn log print_banner require_cmd extract_env_name \
            export_volume_paths _docker_sudo registry_login \
            rollback_save_snapshot fire_hook fire_hook_or_warn \
            notify_event cmd_validate run_cmd

  # Source the module under test.
  source "$CLI_ROOT/lib/deploy_blue_green.sh"

  # Per-test fixture: minimal stack dir + env file.
  STACK="demo"
  CLI_ROOT="$TEST_TMP"
  export CLI_ROOT STACK
  mkdir -p "$CLI_ROOT/stacks/$STACK"
  cat > "$CLI_ROOT/stacks/$STACK/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx
EOF
  cat > "$CLI_ROOT/.test.env" <<'EOF'
DEMO=1
EOF
  ENV_FILE="$CLI_ROOT/.test.env"
  export ENV_FILE

  # Tests run off-tty, so shortcut the drain sleep everywhere.
  export BLUE_GREEN_DRAIN_OVERRIDE=0
  export BLUE_GREEN_HEALTH_TIMEOUT=1
  export BLUE_GREEN_DRAIN=0

  # Sink for observable calls made by stubs.
  CALLS_FILE="$TEST_TMP/calls.log"
  : > "$CALLS_FILE"
  export CALLS_FILE
}

teardown() { common_teardown; }

_record() { echo "$*" >> "$CALLS_FILE"; }

# ── State + colors ───────────────────────────────────────────────────────────

@test "_bg_read_state: missing file yields empty string" {
  run _bg_read_state "$STACK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_bg_write_state + _bg_read_state: round-trips the active color" {
  _bg_write_state "$STACK" "green" "demo-test-green"
  run _bg_read_state "$STACK"
  [ "$status" -eq 0 ]
  [ "$output" = "green" ]
}

@test "_bg_flip_color: blue ↔ green, unknown → blue" {
  [ "$(_bg_flip_color blue)" = "green" ]
  [ "$(_bg_flip_color green)" = "blue" ]
  [ "$(_bg_flip_color "")" = "blue" ]
  [ "$(_bg_flip_color bogus)" = "blue" ]
}

@test "_bg_pick_colors: first deploy yields 'none blue'" {
  run _bg_pick_colors "$STACK"
  [ "$status" -eq 0 ]
  [ "$output" = "none blue" ]
}

@test "_bg_pick_colors: after active=blue → flips to green" {
  _bg_write_state "$STACK" "blue" "demo-test-blue"
  run _bg_pick_colors "$STACK"
  [ "$status" -eq 0 ]
  [ "$output" = "blue green" ]
}

@test "_bg_pick_colors: after active=green → flips to blue" {
  _bg_write_state "$STACK" "green" "demo-test-green"
  run _bg_pick_colors "$STACK"
  [ "$status" -eq 0 ]
  [ "$output" = "green blue" ]
}

# ── Project + compose naming ─────────────────────────────────────────────────

@test "_bg_project_name: with env prepends -<env>-<color>" {
  run _bg_project_name "demo" "prod" "green"
  [ "$status" -eq 0 ]
  [ "$output" = "demo-prod-green" ]
}

@test "_bg_project_name: empty env falls back to stack-<color>" {
  run _bg_project_name "demo" "" "blue"
  [ "$status" -eq 0 ]
  [ "$output" = "demo-blue" ]
}

@test "_bg_compose_for_color: includes env-file, project name, compose file" {
  run _bg_compose_for_color "$STACK" "$ENV_FILE" "green" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"--env-file $ENV_FILE"* ]]
  [[ "$output" == *"--project-name ${STACK}-test-green"* ]]
  [[ "$output" == *"-f $CLI_ROOT/stacks/$STACK/docker-compose.yml"* ]]
}

@test "_bg_compose_for_color: services profile flag when provided" {
  run _bg_compose_for_color "$STACK" "$ENV_FILE" "blue" "full"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--profile full"* ]]
}

# ── Main orchestration: happy path (first deploy → blue) ─────────────────────

@test "bg_deploy_stack: first deploy starts blue, swaps, writes state" {
  # Stub every helper to record and no-op.
  _bg_start_color()   { _record "start:$1"; }
  _bg_wait_healthy()  { _record "wait:$2"; return 0; }
  _bg_swap_proxy()    { _record "swap:$2→$3"; }
  _bg_drain()         { _record "drain:$1"; }
  _bg_stop_color()    { _record "stop:$1"; }
  _bg_teardown_failed_color() { _record "teardown:$1"; }
  export -f _bg_start_color _bg_wait_healthy _bg_swap_proxy _bg_drain _bg_stop_color _bg_teardown_failed_color

  export PRE_DEPLOY_VALIDATE=false  # skip validate path
  export DRY_RUN=false
  export SKIP_VALIDATION=false

  run bg_deploy_stack "$STACK" "$ENV_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Blue-Green Deploy"* ]]
  [[ "$output" == *"first blue-green deploy"* ]]

  # Expected sequence for first deploy: start → wait → swap → (skip drain/stop)
  grep -q "^start:" "$CALLS_FILE"
  grep -q "^wait:"  "$CALLS_FILE"
  grep -q "^swap:demo-test-none→demo-test-blue" "$CALLS_FILE"

  # No drain/stop on first deploy
  ! grep -q "^drain:" "$CALLS_FILE"
  ! grep -q "^stop:"  "$CALLS_FILE"

  # State now tracks blue
  run _bg_read_state "$STACK"
  [ "$output" = "blue" ]
}

@test "bg_deploy_stack: second deploy flips blue → green and drains old" {
  # Seed state as if a previous deploy landed on blue.
  _bg_write_state "$STACK" "blue" "demo-test-blue"

  _bg_start_color()  { _record "start:$1"; }
  _bg_wait_healthy() { _record "wait:ok"; return 0; }
  _bg_swap_proxy()   { _record "swap:$2→$3"; }
  _bg_drain()        { _record "drain:$1"; }
  _bg_stop_color()   { _record "stop:$1"; }
  _bg_teardown_failed_color() { _record "teardown:$1"; }
  export -f _bg_start_color _bg_wait_healthy _bg_swap_proxy _bg_drain _bg_stop_color _bg_teardown_failed_color

  export PRE_DEPLOY_VALIDATE=false DRY_RUN=false SKIP_VALIDATION=false

  run bg_deploy_stack "$STACK" "$ENV_FILE"
  [ "$status" -eq 0 ]

  # Full sequence: start green → wait → swap blue→green → drain → stop blue
  grep -q "^start:" "$CALLS_FILE"
  grep -q "^wait:ok" "$CALLS_FILE"
  grep -q "^swap:demo-test-blue→demo-test-green" "$CALLS_FILE"
  grep -q "^drain:" "$CALLS_FILE"
  grep -q "^stop:" "$CALLS_FILE"

  # Started command targets green; stopped command targets blue
  grep "^start:" "$CALLS_FILE" | grep -q "demo-test-green"
  grep "^stop:"  "$CALLS_FILE" | grep -q "demo-test-blue"

  # State advances to green
  [ "$(_bg_read_state "$STACK")" = "green" ]
}

@test "bg_deploy_stack: health failure tears down green, leaves old color untouched" {
  _bg_write_state "$STACK" "blue" "demo-test-blue"

  _bg_start_color()  { _record "start:$1"; }
  _bg_wait_healthy() { _record "wait:FAIL"; return 1; }
  _bg_swap_proxy()   { _record "swap:$2→$3"; }
  _bg_drain()        { _record "drain:$1"; }
  _bg_stop_color()   { _record "stop:$1"; }
  _bg_teardown_failed_color() { _record "teardown:$1"; }
  export -f _bg_start_color _bg_wait_healthy _bg_swap_proxy _bg_drain _bg_stop_color _bg_teardown_failed_color

  export PRE_DEPLOY_VALIDATE=false DRY_RUN=false SKIP_VALIDATION=false

  run bg_deploy_stack "$STACK" "$ENV_FILE"
  [ "$status" -ne 0 ]

  # Teardown was called on green; swap/drain/stop were NOT.
  grep -q "^teardown:" "$CALLS_FILE"
  grep "^teardown:" "$CALLS_FILE" | grep -q "demo-test-green"
  ! grep -q "^swap:"  "$CALLS_FILE"
  ! grep -q "^drain:" "$CALLS_FILE"
  ! grep -q "^stop:"  "$CALLS_FILE"

  # State is unchanged — blue still active
  [ "$(_bg_read_state "$STACK")" = "blue" ]
}

@test "bg_deploy_stack: dry-run prints plan, touches nothing, no state change" {
  _bg_write_state "$STACK" "blue" "demo-test-blue"
  _bg_start_color()  { _record "start:$1"; }
  _bg_wait_healthy() { _record "wait"; return 0; }
  _bg_swap_proxy()   { _record "swap"; }
  _bg_drain()        { _record "drain"; }
  _bg_stop_color()   { _record "stop"; }
  export -f _bg_start_color _bg_wait_healthy _bg_swap_proxy _bg_drain _bg_stop_color

  export PRE_DEPLOY_VALIDATE=false DRY_RUN=true SKIP_VALIDATION=true

  run bg_deploy_stack "$STACK" "$ENV_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]

  # No helpers were called
  [ ! -s "$CALLS_FILE" ] || {
    echo "Expected empty calls log, got:"; cat "$CALLS_FILE"; false;
  }
  # State unchanged
  [ "$(_bg_read_state "$STACK")" = "blue" ]
}

# ── Proxy swap hook ──────────────────────────────────────────────────────────

@test "_bg_swap_proxy: sources BLUE_GREEN_PROXY_HOOK and calls the function" {
  cat > "$TEST_TMP/hook.sh" <<'EOF'
bluegreen_proxy_swap() {
  echo "HOOK called: stack=$1 old=$2 new=$3 env=$4"
}
EOF
  export BLUE_GREEN_PROXY_HOOK="$TEST_TMP/hook.sh"
  run _bg_swap_proxy "demo" "demo-test-blue" "demo-test-green" "$ENV_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HOOK called"* ]]
  [[ "$output" == *"stack=demo"* ]]
  [[ "$output" == *"old=demo-test-blue"* ]]
  [[ "$output" == *"new=demo-test-green"* ]]
}

@test "_bg_swap_proxy: missing hook file fails loudly" {
  export BLUE_GREEN_PROXY_HOOK="$TEST_TMP/does-not-exist.sh"
  run _bg_swap_proxy "demo" "old" "new" "$ENV_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLUE_GREEN_PROXY_HOOK"* ]] || [[ "$output" == *"missing"* ]]
}

@test "_bg_swap_proxy: hook without bluegreen_proxy_swap fn fails" {
  cat > "$TEST_TMP/bad-hook.sh" <<'EOF'
# no function defined
NOTHING=true
EOF
  export BLUE_GREEN_PROXY_HOOK="$TEST_TMP/bad-hook.sh"
  run _bg_swap_proxy "demo" "old" "new" "$ENV_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not define"* ]] || [[ "$output" == *"bluegreen_proxy_swap"* ]]
}

# ── Rollback flip ────────────────────────────────────────────────────────────

@test "bg_rollback_stack: flips green → blue, brings blue up, stops green" {
  _bg_write_state "$STACK" "green" "demo-test-green"

  # Capture the compose_cmd prefix that up/down receives so we can assert
  # which color each operation targeted.
  _bg_swap_proxy() { _record "swap:$2→$3"; }
  _bg_stop_color() { _record "stop:$1"; }
  export -f _bg_swap_proxy _bg_stop_color

  # Shadow the compose command string so the `$previous_cmd up -d` call
  # inside the orchestrator routes through our recorder.
  _bg_compose_for_color() {
    local color="$3"
    echo "compose-$color"
  }
  export -f _bg_compose_for_color

  # The rollback orchestrator invokes $previous_cmd directly; define a
  # shell function matching the stubbed compose string so it's executable.
  compose-blue() { _record "up:blue:$*"; }
  compose-green() { _record "stop-shadow:green:$*"; }
  export -f compose-blue compose-green

  export DRY_RUN=false

  run bg_rollback_stack "$STACK" "$ENV_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Blue-Green Rollback"* ]]

  grep -q "^up:blue:" "$CALLS_FILE"
  grep -q "^swap:demo-test-green→demo-test-blue" "$CALLS_FILE"
  grep -q "^stop:compose-green" "$CALLS_FILE"

  # State flipped to blue
  [ "$(_bg_read_state "$STACK")" = "blue" ]
}

@test "bg_rollback_stack: no state → fails cleanly" {
  _bg_clear_state "$STACK"
  run bg_rollback_stack "$STACK" "$ENV_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No blue-green state"* ]] || [[ "$output" == *"standard rollback"* ]]
}

@test "bg_rollback_stack: dry-run prints plan and doesn't flip state" {
  _bg_write_state "$STACK" "green" "demo-test-green"
  export DRY_RUN=true

  run bg_rollback_stack "$STACK" "$ENV_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ "$(_bg_read_state "$STACK")" = "green" ]
}
