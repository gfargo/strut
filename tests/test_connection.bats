#!/usr/bin/env bats
# ==================================================
# tests/test_connection.bats — Tests for lib/connection.sh
# ==================================================
# Run:  bats tests/test_connection.bats
# Covers: resolve_connection_from_host_alias, cross-host isolation

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  export REAL_CLI_ROOT="$CLI_ROOT"

  source "$CLI_ROOT/lib/topology.sh"
  source "$CLI_ROOT/lib/connection.sh"

  # Reset topology state
  _TOPO_HOSTS=()
  _TOPO_STACK_HOST=()
  _TOPO_LOADED=false

  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP"
}

teardown() {
  common_teardown
}

# ── resolve_connection_from_host_alias: cross-host isolation ────────────────

@test "resolve_connection_from_host_alias: host without deploy_dir does not inherit prior host's deploy dir" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
alpha = deploy@a.example /keys/a deploy_dir=/opt/appA
beta  = deploy@b.example
EOF
  export PROJECT_ROOT="$TEST_TMP"
  _TOPO_LOADED=false

  run resolve_connection_from_host_alias alpha
  [ "$status" -eq 0 ]

  resolve_connection_from_host_alias alpha
  [ "$VPS_DEPLOY_DIR" = "/opt/appA" ]
  [ "$VPS_SSH_KEY" = "/keys/a" ]

  resolve_connection_from_host_alias beta
  [ "$VPS_DEPLOY_DIR" = "/home/deploy/strut" ]
  [ "$VPS_DEPLOY_DIR" != "/opt/appA" ]
}

@test "resolve_connection_from_host_alias: host without inline key does not inherit prior host's key" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
alpha = deploy@a.example /keys/a deploy_dir=/opt/appA
beta  = deploy@b.example
EOF
  export PROJECT_ROOT="$TEST_TMP"
  _TOPO_LOADED=false

  resolve_connection_from_host_alias alpha
  [ "$VPS_SSH_KEY" = "/keys/a" ]

  resolve_connection_from_host_alias beta
  [ "$VPS_SSH_KEY" = "" ]
  [ "$VPS_SSH_KEY" != "/keys/a" ]
}

@test "resolve_connection_from_host_alias: not-found branch still falls back to env vars" {
  export VPS_HOST="env.example.com"
  export VPS_USER="envuser"
  export VPS_SSH_KEY="/env/key"
  export VPS_DEPLOY_DIR="/env/deploy"
  _TOPO_LOADED=true

  run resolve_connection_from_host_alias nonexistent-host
  [ "$status" -eq 0 ]

  resolve_connection_from_host_alias nonexistent-host
  [ "$VPS_HOST" = "env.example.com" ]
  [ "$VPS_SSH_KEY" = "/env/key" ]
  [ "$VPS_DEPLOY_DIR" = "/env/deploy" ]
}

# ── parse_host_spec: arch= (OSS-262) ──────────────────────────────────────────

@test "parse_host_spec: parses arch= alongside a key path and deploy_dir=" {
  parse_host_spec "pi@raspi.local:22 /keys/pi deploy_dir=/opt/app arch=arm64"
  [ "$CONN_HOST" = "raspi.local" ]
  [ "$CONN_KEY" = "/keys/pi" ]
  [ "$CONN_DEPLOY_DIR" = "/opt/app" ]
  [ "$CONN_ARCH" = "arm64" ]
}

@test "parse_host_spec: arch= works with no key path" {
  parse_host_spec "pi@raspi.local arch=arm64"
  [ "$CONN_ARCH" = "arm64" ]
  [ "$CONN_KEY" = "" ]
}

@test "parse_host_spec: option order doesn't matter (arch= before deploy_dir=)" {
  parse_host_spec "deploy@box:22 arch=amd64 deploy_dir=/opt/stacks /keys/id"
  [ "$CONN_ARCH" = "amd64" ]
  [ "$CONN_DEPLOY_DIR" = "/opt/stacks" ]
  [ "$CONN_KEY" = "/keys/id" ]
}

@test "parse_host_spec: CONN_ARCH defaults to empty when not declared" {
  parse_host_spec "harbor"
  [ "$CONN_ARCH" = "" ]
}
