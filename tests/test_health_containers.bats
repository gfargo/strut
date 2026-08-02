#!/usr/bin/env bats
# ==================================================
# tests/test_health_containers.bats — health_check_containers project-name
# mismatch fallback (strut#502)
# ==================================================
# Run:  bats tests/test_health_containers.bats
# Covers: health_check_containers falling back to a working-dir label match
# when `compose ps` (scoped to the resolved --project-name) returns nothing
# even though the stack's containers are actually running under a different
# project name. Runs in JSON mode (HEALTH_JSON_OUTPUT=true) to match the real
# `strut mcp serve` / `--json` path the bug was reported against, and calls
# health_check_containers directly (not via command substitution) so the
# HEALTH_* counters are inspectable afterward.

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_health() {
  source "$CLI_ROOT/lib/utils.sh"
  # Override fail to not exit the test runner
  fail() { echo "$1" >&2; return 1; }
  source "$CLI_ROOT/lib/health.sh"
  # Reset health state — JSON mode matches the strut mcp serve / --json path
  HEALTH_OVERALL="healthy"
  HEALTH_PASSED=0
  HEALTH_FAILED=0
  HEALTH_WARNED=0
  HEALTH_JSON_RESULTS="[]"
  HEALTH_JSON_OUTPUT=true
}

_make_compose_file() {
  local stack_dir="$TEST_TMP/observability"
  mkdir -p "$stack_dir"
  local compose_file="$stack_dir/docker-compose.yml"
  echo "services: {}" > "$compose_file"
  echo "$compose_file"
}

# ── Mismatch fallback ─────────────────────────────────────────────────────────

@test "health_check_containers: falls back to working-dir label match when compose ps is empty (project name mismatch)" {
  _load_health
  local compose_file; compose_file=$(_make_compose_file)

  # Simulate `compose ps` returning nothing — wrong/stale project name
  # shellcheck disable=SC2317
  compose_cmd_stub() {
    [ "$1" = "ps" ] && return 0
  }
  export -f compose_cmd_stub

  # shellcheck disable=SC2317
  docker() {
    [ "$1" = "ps" ] || return 0
    echo "grafana|running|Up 3 hours (healthy)"
    echo "loki|running|Up 3 hours"
  }
  export -f docker

  local status=0
  health_check_containers "compose_cmd_stub" "$compose_file" || status=$?
  [ "$status" -eq 0 ]
  [ "$HEALTH_PASSED" -ge 2 ]
  [ "$HEALTH_FAILED" -eq 0 ]
  [[ "$HEALTH_JSON_RESULTS" != *"No containers running"* ]]
  [[ "$HEALTH_JSON_RESULTS" == *"grafana"* ]]
  [[ "$HEALTH_JSON_RESULTS" == *"loki"* ]]
}

# ── Truly empty ───────────────────────────────────────────────────────────────

@test "health_check_containers: reports 'No containers running' when both compose ps and the fallback are empty" {
  _load_health
  local compose_file; compose_file=$(_make_compose_file)

  # shellcheck disable=SC2317
  compose_cmd_stub() {
    [ "$1" = "ps" ] && return 0
  }
  export -f compose_cmd_stub

  # shellcheck disable=SC2317
  docker() {
    [ "$1" = "ps" ] && return 0
  }
  export -f docker

  local status=0
  health_check_containers "compose_cmd_stub" "$compose_file" || status=$?
  [ "$status" -eq 1 ]
  [ "$HEALTH_FAILED" -eq 1 ]
  [[ "$HEALTH_JSON_RESULTS" == *"No containers running"* ]]
}

# ── Unhealthy container surfaced via fallback ────────────────────────────────

@test "health_check_containers: fallback container with (unhealthy) status records a warn" {
  _load_health
  local compose_file; compose_file=$(_make_compose_file)

  # shellcheck disable=SC2317
  compose_cmd_stub() {
    [ "$1" = "ps" ] && return 0
  }
  export -f compose_cmd_stub

  # shellcheck disable=SC2317
  docker() {
    [ "$1" = "ps" ] || return 0
    echo "flaky-svc|running|Up 10 minutes (unhealthy)"
  }
  export -f docker

  local status=0
  health_check_containers "compose_cmd_stub" "$compose_file" || status=$?
  [ "$status" -eq 0 ]
  [ "$HEALTH_WARNED" -eq 1 ]
  [ "$HEALTH_FAILED" -eq 0 ]
  [[ "$HEALTH_JSON_RESULTS" == *"flaky-svc"* ]]
}

# ── Missing compose file — unchanged ─────────────────────────────────────────

@test "health_check_containers: missing compose file still fails without attempting a fallback" {
  _load_health
  local compose_file="$TEST_TMP/does-not-exist/docker-compose.yml"

  # shellcheck disable=SC2317
  docker() { echo "unexpected docker call" >&2; return 1; }
  export -f docker

  local status=0
  health_check_containers "compose_cmd_stub_unused" "$compose_file" || status=$?
  [ "$status" -eq 1 ]
  [ "$HEALTH_FAILED" -eq 1 ]
  [[ "$HEALTH_JSON_RESULTS" == *"Compose File"* ]]
}
