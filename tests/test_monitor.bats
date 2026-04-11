#!/usr/bin/env bats
# ==================================================
# tests/test_monitor.bats — Tests for monitoring module
# ==================================================
# Run:  bats tests/test_monitor.bats
# Covers: monitoring_status, monitoring_is_running,
#         wait_for_service (timeout behavior)

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  # Create the monitoring stack dir before sourcing monitor.sh
  mkdir -p "$CLI_ROOT/stacks/monitoring"

  source "$CLI_ROOT/lib/monitor.sh"

  # Now override MONITORING_STACK_DIR to our test dir
  MONITORING_STACK_DIR="$TEST_TMP/monitoring"
  mkdir -p "$MONITORING_STACK_DIR"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── monitoring_is_running ─────────────────────────────────────────────────────

@test "monitoring_is_running: returns 1 when no containers running" {
  # Override docker to simulate no containers
  docker() { echo ""; }
  export -f docker

  run monitoring_is_running
  [ "$status" -eq 1 ]

  unset -f docker
}

# ── monitoring_status ─────────────────────────────────────────────────────────

@test "monitoring_status: text output includes service names" {
  # Stub docker ps to return nothing (services down)
  docker() { echo ""; }
  export -f docker

  run monitoring_status "text"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prometheus"* ]]
  [[ "$output" == *"Grafana"* ]]
  [[ "$output" == *"Alertmanager"* ]]

  unset -f docker
}

@test "monitoring_status: json output is valid JSON" {
  docker() { echo ""; }
  export -f docker

  run monitoring_status "json"
  [ "$status" -eq 0 ]
  # Filter out log lines (colored [strut] prefix) and parse only the JSON block
  local json_output
  json_output=$(echo "$output" | grep -v '^\[strut\]' | grep -v '^\x1b' | grep -v '^$' | grep '{' -A 100)
  echo "$json_output" | jq empty

  unset -f docker
}

@test "monitoring_status: json shows all services as down when not running" {
  docker() { echo ""; }
  export -f docker

  run monitoring_status "json"
  [ "$status" -eq 0 ]
  local json_output
  json_output=$(echo "$output" | grep -v '^\[strut\]' | grep -v '^\x1b' | grep -v '^$' | grep '{' -A 100)
  [ "$(echo "$json_output" | jq -r '.services.prometheus')" = "down" ]
  [ "$(echo "$json_output" | jq -r '.services.grafana')" = "down" ]
  [ "$(echo "$json_output" | jq -r '.services.alertmanager')" = "down" ]

  unset -f docker
}

@test "monitoring_status: json shows services as up when running" {
  # Stub docker ps to simulate running containers
  docker() {
    case "$*" in
      *ps*) echo "prometheus grafana alertmanager node-exporter cadvisor" ;;
      *) command docker "$@" 2>/dev/null || true ;;
    esac
  }
  export -f docker

  run monitoring_status "json"
  [ "$status" -eq 0 ]
  local json_output
  json_output=$(echo "$output" | grep -v '^\[strut\]' | grep -v '^\x1b' | grep -v '^$' | grep '{' -A 100)
  [ "$(echo "$json_output" | jq -r '.services.prometheus')" = "up" ]
  [ "$(echo "$json_output" | jq -r '.services.grafana')" = "up" ]
  [ "$(echo "$json_output" | jq -r '.services.alertmanager')" = "up" ]

  unset -f docker
}

# ── monitoring_deploy ─────────────────────────────────────────────────────────

@test "monitoring_deploy: fails when monitoring directory missing" {
  rm -rf "$MONITORING_STACK_DIR"

  run monitoring_deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

# ── monitoring_add_target ─────────────────────────────────────────────────────

@test "monitoring_add_target: fails without stack name" {
  run monitoring_add_target ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "monitoring_add_target: creates target YAML file" {
  mkdir -p "$MONITORING_STACK_DIR/prometheus/targets"

  # Stub docker and monitoring_is_running
  docker() { echo ""; }
  export -f docker

  run monitoring_add_target "my-app" "prod"
  [ "$status" -eq 0 ]
  [ -f "$MONITORING_STACK_DIR/prometheus/targets/my-app.yml" ]
  grep -q "stack: 'my-app'" "$MONITORING_STACK_DIR/prometheus/targets/my-app.yml"
  grep -q "environment: 'prod'" "$MONITORING_STACK_DIR/prometheus/targets/my-app.yml"

  unset -f docker
}

# ── monitoring_remove_target ──────────────────────────────────────────────────

@test "monitoring_remove_target: fails without stack name" {
  run monitoring_remove_target ""
  [ "$status" -eq 1 ]
}

@test "monitoring_remove_target: fails when target file missing" {
  run monitoring_remove_target "nonexistent-stack"
  [ "$status" -eq 1 ]
}

@test "monitoring_remove_target: removes target file" {
  mkdir -p "$MONITORING_STACK_DIR/prometheus/targets"
  echo "targets:" > "$MONITORING_STACK_DIR/prometheus/targets/my-app.yml"

  docker() { echo ""; }
  export -f docker

  run monitoring_remove_target "my-app"
  [ "$status" -eq 0 ]
  [ ! -f "$MONITORING_STACK_DIR/prometheus/targets/my-app.yml" ]

  unset -f docker
}

# ── monitoring_alert_channel_add ──────────────────────────────────────────────

@test "monitoring_alert_channel_add: fails for unknown channel type" {
  run monitoring_alert_channel_add "carrier-pigeon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown channel type"* ]]
}
