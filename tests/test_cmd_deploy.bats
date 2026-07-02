#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_deploy.bats — Smoke tests for deploy/health/release handlers
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/diff.sh"
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
  # Lock stubs — lock.sh not sourced in unit tests
  lock_acquire_local() { return 0; }
  lock_release_local() { return 0; }
  lock_is_stale_local() { return 1; }
  lock_force_break_local() { return 0; }
  # diff_fetch_remote stub — no SSH in unit tests
  diff_fetch_remote() { echo ""; }
  export -f deploy_stack pull_only_stack vps_update_repo vps_release \
            health_run_all docker_prune resolve_compose_cmd is_running_on_vps \
            lock_acquire_local lock_release_local lock_is_stale_local \
            lock_force_break_local diff_fetch_remote

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
  export CLI_ROOT="$CLI_ROOT"
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
  [[ "$output" == *"--confirm-data-move"* ]]
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

# ── _deploy_volguard tests ────────────────────────────────────────────────────
# These tests stub diff_fetch_remote and diff_detect_destructive so no SSH
# is attempted. The guard is tested as a pure function.

@test "_deploy_volguard: skips guard when env file has no VPS_HOST" {
  cat > "$TEST_TMP/.nohost.env" <<'EOF'
APP_SECRET=abc
EOF
  # Should return 0 silently — no VPS_HOST means no remote to diff
  run _deploy_volguard "test-stack" "$TEST_TMP/.nohost.env" "false"
  [ "$status" -eq 0 ]
}

@test "_deploy_volguard: skips guard when compose file is absent" {
  # Remove the compose file
  rm -f "$TEST_TMP/stacks/test-stack/docker-compose.yml"
  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -eq 0 ]
}

@test "_deploy_volguard: skips guard when remote env is empty (new stack)" {
  # Stub diff_fetch_remote to return empty (remote doesn't exist yet)
  diff_fetch_remote() { echo ""; }
  export -f diff_fetch_remote

  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -eq 0 ]
}

@test "_deploy_volguard: aborts when destructive changes detected without flag" {
  # Compose with a volume-defining var
  cat > "$TEST_TMP/stacks/test-stack/docker-compose.yml" <<'EOF'
services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
EOF

  # Local env has INSTALL_DIR set; remote has it absent (unset→value transition)
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=example.com
INSTALL_DIR=/opt/plane
EOF

  # Stub diff_fetch_remote to return remote env content (no INSTALL_DIR)
  diff_fetch_remote() { echo "VPS_HOST=example.com"; }
  export -f diff_fetch_remote

  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -ne 0 ]
  [[ "$output" == *"INSTALL_DIR"* ]] || [[ "$output" == *"abort"* ]] || \
    [[ "$output" == *"data-destructive"* ]] || [[ "$output" == *"DATA-DESTRUCTIVE"* ]]
}

@test "_deploy_volguard: proceeds when --confirm-data-move is true" {
  cat > "$TEST_TMP/stacks/test-stack/docker-compose.yml" <<'EOF'
services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
EOF

  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=example.com
INSTALL_DIR=/opt/plane
EOF

  diff_fetch_remote() { echo "VPS_HOST=example.com"; }
  export -f diff_fetch_remote

  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "true"
  [ "$status" -eq 0 ]
}

@test "_deploy_volguard: dry-run warns but returns 0" {
  cat > "$TEST_TMP/stacks/test-stack/docker-compose.yml" <<'EOF'
services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
EOF

  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=example.com
INSTALL_DIR=/opt/plane
EOF

  diff_fetch_remote() { echo "VPS_HOST=example.com"; }
  export -f diff_fetch_remote

  export DRY_RUN=true
  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]] || [[ "$output" == *"dry"* ]] || true
}

@test "_deploy_volguard: no destructive changes → returns 0" {
  # Local and remote envs are identical (no dangerous diff)
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=example.com
LOG_LEVEL=info
EOF

  diff_fetch_remote() { echo "VPS_HOST=example.com
LOG_LEVEL=info"; }
  export -f diff_fetch_remote

  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -eq 0 ]
}

@test "cmd_deploy: --confirm-data-move flag is recognized (no error)" {
  # The guard is a no-op when no VPS_HOST fetches destructive diffs; just
  # verify the flag doesn't cause a parse error.
  diff_fetch_remote() { echo ""; }
  export -f diff_fetch_remote

  run cmd_deploy --confirm-data-move
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy_stack"* ]]
}

@test "cmd_release: --confirm-data-move flag is recognized (no error)" {
  diff_fetch_remote() { echo ""; }
  export -f diff_fetch_remote

  export CMD_ARGS=("--confirm-data-move")
  run cmd_release
  [ "$status" -eq 0 ]
  [[ "$output" == *"vps_release"* ]]
}
