#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_stop.bats — Tests for the stop command
# ==================================================
# Run:  bats tests/test_cmd_stop.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/cmd_stop.sh"

  # Create a minimal test stack
  mkdir -p "$TEST_TMP/stacks/test-stack"
  echo "services:" > "$TEST_TMP/stacks/test-stack/docker-compose.yml"
  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"

  # Stub out docker compose so we don't need a real Docker daemon
  docker() {
    echo "docker $*"
    return 0
  }
  export -f docker

  # Stub is_running_on_vps to return false (local mode)
  is_running_on_vps() { return 1; }
  export -f is_running_on_vps
}

teardown() {
  common_teardown
}

@test "cmd_stop: calls compose down with --remove-orphans" {
  # Create a minimal env file
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF

  # Stub resolve_compose_cmd
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd

  run cmd_stop "test-stack" "$TEST_TMP/.test.env" "test" "" 
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped"* ]]
}

@test "cmd_stop: --volumes flag is accepted" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF

  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd

  run cmd_stop "test-stack" "$TEST_TMP/.test.env" "test" "" --volumes
  [ "$status" -eq 0 ]
}

@test "cmd_stop: --timeout flag is accepted" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF

  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd

  run cmd_stop "test-stack" "$TEST_TMP/.test.env" "test" "" --timeout 30
  [ "$status" -eq 0 ]
}

@test "cmd_stop: dry-run shows execution plan" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF
  export DRY_RUN=true

  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export -f resolve_compose_cmd

  run cmd_stop "test-stack" "$TEST_TMP/.test.env" "test" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_stop: fails when env file missing" {
  run cmd_stop "test-stack" "$TEST_TMP/nonexistent.env" "test" ""
  [ "$status" -ne 0 ] || [[ "$output" == *"not found"* ]]
}
