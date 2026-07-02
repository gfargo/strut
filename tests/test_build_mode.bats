#!/usr/bin/env bats
# ==================================================
# tests/test_build_mode.bats — Tests for BUILD_MODE support in deploy
# ==================================================
# Run:  bats tests/test_build_mode.bats
# Covers: BUILD_MODE=local|registry|none in deploy_stack and pull_only_stack

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_docker

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/deploy.sh"

  # Stubs for functions called during deploy
  registry_login() { echo "REGISTRY_LOGIN_CALLED"; }
  docker_pull_stack() { echo "DOCKER_PULL_CALLED: $*"; }
  rollback_save_snapshot() { :; }
  export_volume_paths() { :; }
  fire_hook() { return 0; }
  fire_hook_or_warn() { :; }
  fire_first_run_hook() { :; }
  maybe_apply_db_schema() { :; }
  notify_event() { :; }
  print_banner() { :; }
  require_cmd() { :; }
  is_running_on_vps() { return 0; }
  export -f registry_login docker_pull_stack rollback_save_snapshot \
            export_volume_paths fire_hook fire_hook_or_warn \
            fire_first_run_hook maybe_apply_db_schema \
            notify_event print_banner require_cmd is_running_on_vps

  # Create stack structure
  mkdir -p "$TEST_TMP/stacks/hub"
  cat > "$TEST_TMP/stacks/hub/docker-compose.yml" <<'EOF'
services:
  app:
    build: .
    image: hub-app
EOF

  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
EOF

  export CLI_ROOT="$TEST_TMP"
  export DRY_RUN="false"
  export PRE_DEPLOY_VALIDATE="false"
}

teardown() {
  common_teardown
}

# ── pull_only_stack with BUILD_MODE ──────────────────────────────────────────

@test "pull_only_stack: BUILD_MODE=registry calls registry_login and docker_pull" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=registry
API_PORT=8000
EOF

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"REGISTRY_LOGIN_CALLED"* ]]
  [[ "$output" == *"DOCKER_PULL_CALLED"* ]]
}

@test "pull_only_stack: BUILD_MODE=local runs docker compose build instead of pull" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=local
EOF

  # Stub docker and compose to capture the build command
  docker() {
    if [[ "$1" == "compose" ]]; then
      echo "DOCKER_COMPOSE $*"
      return 0
    fi
  }
  export -f docker

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"build"* ]]
  [[ "$output" != *"REGISTRY_LOGIN_CALLED"* ]]
  [[ "$output" != *"DOCKER_PULL_CALLED"* ]]
}

@test "pull_only_stack: BUILD_MODE=none skips both pull and build" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=none
EOF

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"REGISTRY_LOGIN_CALLED"* ]]
  [[ "$output" != *"DOCKER_PULL_CALLED"* ]]
  [[ "$output" == *"Nothing to pull or build"* ]]
}

@test "pull_only_stack: no BUILD_MODE defaults to registry behavior" {
  # No services.conf at all
  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"REGISTRY_LOGIN_CALLED"* ]]
  [[ "$output" == *"DOCKER_PULL_CALLED"* ]]
}

# ── BUILD_ARGS, BUILD_PULL, BUILD_PARALLEL ───────────────────────────────────

@test "pull_only_stack: BUILD_ARGS are passed to docker compose build" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=local
BUILD_ARGS=--no-cache
BUILD_PULL=true
BUILD_PARALLEL=true
EOF

  docker() {
    if [[ "$1" == "compose" ]]; then
      echo "DOCKER_COMPOSE $*"
      return 0
    fi
  }
  export -f docker

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-cache"* ]]
  [[ "$output" == *"--pull"* ]]
  [[ "$output" == *"--parallel"* ]]
}

# ── Validation ───────────────────────────────────────────────────────────────

@test "validate: BUILD_MODE=local is valid" {
  source "$CLI_ROOT/../lib/cmd_validate.sh" 2>/dev/null || source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/cmd_validate.sh"

  # Reset CLI_ROOT to real project for validation functions
  local real_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  mkdir -p "$TEST_TMP/validate-stack"
  cat > "$TEST_TMP/validate-stack/services.conf" <<'EOF'
BUILD_MODE=local
BUILD_PULL=true
BUILD_PARALLEL=false
API_PORT=8000
EOF

  # Capture validation output
  _val_ok() { echo "OK: $1 $2"; }
  _val_error() { echo "ERROR: $1 $2"; return 1; }
  _val_warn() { echo "WARN: $1 $2"; }

  run _validate_services_conf "$TEST_TMP/validate-stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  [[ "$output" != *"ERROR"* ]]
}

@test "validate: BUILD_MODE=invalid is rejected" {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/cmd_validate.sh"

  mkdir -p "$TEST_TMP/validate-bad"
  cat > "$TEST_TMP/validate-bad/services.conf" <<'EOF'
BUILD_MODE=invalid
EOF

  _val_ok() { echo "OK: $1 $2"; }
  _val_error() { echo "ERROR: $1 $2"; }
  _val_warn() { echo "WARN: $1 $2"; }
  _is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
  _is_valid_boolean() { [[ "$1" == "true" || "$1" == "false" ]]; }

  run _validate_services_conf "$TEST_TMP/validate-bad"
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"BUILD_MODE"* ]]
  [[ "$output" == *"must be local, registry, or none"* ]]
}
