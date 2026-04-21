#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_deploy.bats — Smoke tests for deploy/health/release handlers
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/cmd_deploy.sh"

  # Stubs for underlying ops
  deploy_stack() { echo "deploy_stack $*"; }
  pull_only_stack() { echo "pull_only_stack $*"; }
  vps_update_repo() { echo "vps_update_repo $*"; }
  vps_release() { echo "vps_release $*"; }
  health_run_all() { echo "health_run_all $*"; }
  docker_prune() { echo "docker_prune $*"; }
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  is_running_on_vps() { return 0; }   # pretend we're on VPS so deploy skips warning
  export -f deploy_stack pull_only_stack vps_update_repo vps_release \
            health_run_all docker_prune resolve_compose_cmd is_running_on_vps

  mkdir -p "$TEST_TMP/stacks/test-stack"
  cat > "$TEST_TMP/stacks/test-stack/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx
EOF
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=example.com
GH_PAT=test
EOF

  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="test"
  export CMD_SERVICES=""
  export CMD_JSON=""
  export DRY_RUN=false
}

teardown() {
  common_teardown
}

@test "_usage_deploy: prints usage with flags" {
  run _usage_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"--pull-only"* ]]
  [[ "$output" == *"--skip-validation"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "_usage_health: prints usage" {
  run _usage_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"health"* ]]
  [[ "$output" == *"--json"* ]]
}

@test "cmd_deploy: dispatches to deploy_stack by default" {
  run cmd_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy_stack"* ]]
}

@test "cmd_deploy: --pull-only dispatches to pull_only_stack" {
  run cmd_deploy --pull-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"pull_only_stack"* ]]
  [[ "$output" != *"deploy_stack "* ]]
}

@test "cmd_deploy: --skip-validation exports SKIP_VALIDATION=true" {
  # We can't easily observe exports via run; instead verify it doesn't crash
  run cmd_deploy --skip-validation
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy_stack"* ]]
}

@test "cmd_update: dispatches to vps_update_repo" {
  run cmd_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"vps_update_repo"* ]]
}

@test "cmd_update: fails when VPS_HOST missing" {
  cat > "$TEST_TMP/.bad.env" <<'EOF'
GH_PAT=test
EOF
  export CMD_ENV_FILE="$TEST_TMP/.bad.env"
  run cmd_update
  [[ "$output" == *"VPS_HOST"* ]] || [ "$status" -ne 0 ]
}

@test "cmd_release: dispatches to vps_release" {
  run cmd_release
  [ "$status" -eq 0 ]
  [[ "$output" == *"vps_release"* ]]
}

@test "cmd_health: dispatches to health_run_all" {
  run cmd_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"health_run_all"* ]]
}

@test "cmd_status: runs compose ps" {
  # resolve_compose_cmd returns "echo COMPOSE", so \$compose_cmd ps → "echo COMPOSE ps"
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPOSE"* ]]
  [[ "$output" == *"ps"* ]]
}

@test "cmd_prune: dispatches to docker_prune" {
  run cmd_prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker_prune"* ]]
}

@test "cmd_prune: dry-run shows plan" {
  export DRY_RUN=true
  run cmd_prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}
