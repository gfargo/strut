#!/usr/bin/env bats
# ==================================================
# tests/test_services_conf.bats — Tests for load_services_conf
# ==================================================
# Run:  bats tests/test_services_conf.bats

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_utils() {
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"
  fail() { echo "$1" >&2; return 1; }
}

# ── load_services_conf ────────────────────────────────────────────────────────

@test "load_services_conf: sources variables from services.conf" {
  _load_utils
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/services.conf" <<'EOF'
CH_API_PORT=9000
CH_API_PATH="/api/v2"
GRAFANA_PORT=3001
EOF
  load_services_conf "$TEST_TMP/stack"
  [ "$CH_API_PORT" = "9000" ]
  [ "$CH_API_PATH" = "/api/v2" ]
  [ "$GRAFANA_PORT" = "3001" ]
}

@test "load_services_conf: no-op when services.conf missing" {
  _load_utils
  mkdir -p "$TEST_TMP/stack"
  # Should not fail
  load_services_conf "$TEST_TMP/stack"
}

@test "load_services_conf: real knowledge-graph services.conf loads" {
  _load_utils
  local stack_dir="$CLI_ROOT/stacks/knowledge-graph"
  if [ -f "$stack_dir/services.conf" ]; then
    load_services_conf "$stack_dir"
    # Should have at least CH_API_PORT defined
    [ -n "${CH_API_PORT:-}" ]
  else
    skip "knowledge-graph/services.conf not found"
  fi
}
