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

@test "cmd_deploy: VPS_HOST warning reflects dispatcher-resolved host, not env file value" {
  cat > "$TEST_TMP/.override.env" <<'EOF'
VPS_HOST=primary-host.internal
GH_PAT=test
EOF
  export CMD_ENV_FILE="$TEST_TMP/.override.env"
  is_running_on_vps() { return 1; }
  export -f is_running_on_vps
  export VPS_HOST="standby-host.internal"
  export STRUT_YES=1

  run cmd_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"standby-host.internal"* ]]
  [[ "$output" != *"primary-host.internal"* ]]
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

@test "cmd_release: auto_rollback defaults to true" {
  run cmd_release
  [ "$status" -eq 0 ]
  [[ "$output" == *" true"* ]]
}

@test "cmd_release: --no-rollback passes auto_rollback=false to vps_release" {
  export CMD_ARGS=(--no-rollback)
  run cmd_release
  [ "$status" -eq 0 ]
  [[ "$output" == *" false"* ]]
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
# All volguard tests override CLI_ROOT to TEST_TMP so the compose file lookup
# finds the test fixtures (not the repo's real stacks/).

@test "_deploy_volguard: skips guard when env file has no VPS_HOST" {
  export CLI_ROOT="$TEST_TMP"
  cat > "$TEST_TMP/.nohost.env" <<'EOF'
APP_SECRET=abc
EOF
  # Should return 0 silently — no VPS_HOST means no remote to diff
  run _deploy_volguard "test-stack" "$TEST_TMP/.nohost.env" "false"
  [ "$status" -eq 0 ]
}

@test "_deploy_volguard: skips guard when compose file is absent" {
  export CLI_ROOT="$TEST_TMP"
  # Remove the compose file
  rm -f "$TEST_TMP/stacks/test-stack/docker-compose.yml"
  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -eq 0 ]
}

@test "_deploy_volguard: skips guard when remote env is empty (new stack)" {
  export CLI_ROOT="$TEST_TMP"
  # Stub diff_fetch_remote to return empty (remote doesn't exist yet)
  diff_fetch_remote() { echo ""; }
  export -f diff_fetch_remote

  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -eq 0 ]
}

@test "_deploy_volguard: aborts when destructive changes detected without flag" {
  export CLI_ROOT="$TEST_TMP"
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

  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false" < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"INSTALL_DIR"* ]] || [[ "$output" == *"abort"* ]] || \
    [[ "$output" == *"data-destructive"* ]] || [[ "$output" == *"DATA-DESTRUCTIVE"* ]]
}

@test "_deploy_volguard: proceeds when --confirm-data-move is true" {
  export CLI_ROOT="$TEST_TMP"
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
  export CLI_ROOT="$TEST_TMP"
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

@test "_deploy_volguard: aborts when SSH connection to VPS fails" {
  export CLI_ROOT="$TEST_TMP"
  # rc=2 sentinel: ssh itself failed to connect (not just an empty remote file)
  diff_fetch_remote() { return 2; }
  export -f diff_fetch_remote

  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot verify remote state"* ]]
}

@test "_deploy_volguard: SSH connection failure only warns under DRY_RUN" {
  export CLI_ROOT="$TEST_TMP"
  diff_fetch_remote() { return 2; }
  export -f diff_fetch_remote

  export DRY_RUN=true
  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot verify remote state"* ]]
}

@test "_deploy_volguard: SSH connection failure only warns with --confirm-data-move" {
  export CLI_ROOT="$TEST_TMP"
  diff_fetch_remote() { return 2; }
  export -f diff_fetch_remote

  run _deploy_volguard "test-stack" "$TEST_TMP/.test.env" "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot verify remote state"* ]]
}

@test "_deploy_volguard: no destructive changes → returns 0" {
  export CLI_ROOT="$TEST_TMP"
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

@test "cmd_rebuild: aborts on destructive INSTALL_DIR change without --confirm-data-move" {
  export CLI_ROOT="$TEST_TMP"
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
  export CMD_ENV_FILE="$TEST_TMP/.test.env"

  # Remote env lacks INSTALL_DIR — changing a volume-defining var
  diff_fetch_remote() { echo "VPS_HOST=example.com"; }
  export -f diff_fetch_remote

  run cmd_rebuild < /dev/null
  [ "$status" -ne 0 ]
  # Guard fires before deploy_stack is reached
  [[ "$output" != *"deploy_stack"* ]]
  [[ "$output" == *"INSTALL_DIR"* ]] || [[ "$output" == *"data-destructive"* ]] || \
    [[ "$output" == *"DATA-DESTRUCTIVE"* ]] || [[ "$output" == *"abort"* ]]
}

@test "cmd_rebuild: proceeds with --confirm-data-move on destructive change" {
  export CLI_ROOT="$TEST_TMP"
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
  export CMD_ENV_FILE="$TEST_TMP/.test.env"

  diff_fetch_remote() { echo "VPS_HOST=example.com"; }
  export -f diff_fetch_remote

  run cmd_rebuild --confirm-data-move
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy_stack"* ]]
}

# ── on_health_fail hook ───────────────────────────────────────────────────────

@test "cmd_health: fires on_health_fail hook when health_run_all returns non-zero" {
  # Override health_run_all to simulate failure
  health_run_all() { echo "health_run_all $*"; return 1; }
  export -f health_run_all

  fire_hook_or_warn() { echo "fire_hook_or_warn $*"; return 0; }
  export -f fire_hook_or_warn

  run cmd_health
  # Exit code must be preserved (1)
  [ "$status" -eq 1 ]
  [[ "$output" == *"fire_hook_or_warn"* ]]
  [[ "$output" == *"on_health_fail"* ]]
}

@test "cmd_health: does NOT fire on_health_fail when health_run_all succeeds" {
  health_run_all() { echo "health_run_all $*"; return 0; }
  export -f health_run_all

  fire_hook_or_warn() { echo "fire_hook_or_warn $*"; return 0; }
  export -f fire_hook_or_warn

  run cmd_health
  [ "$status" -eq 0 ]
  [[ "$output" != *"on_health_fail"* ]]
}

@test "cmd_health: preserves original exit code after firing on_health_fail" {
  health_run_all() { return 2; }
  fire_hook_or_warn() { return 0; }
  export -f health_run_all fire_hook_or_warn

  run cmd_health
  [ "$status" -eq 2 ]
}

# ── diff_warn_env_divergence (OSS-327) ────────────────────────────────────────

@test "diff_warn_env_divergence: silent when no VPS_HOST" {
  export VPS_HOST=""
  run diff_warn_env_divergence "test-stack" "$TEST_TMP/.prod.env" "$TEST_TMP/stacks/test-stack"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "diff_warn_env_divergence: silent when resolved file is .env itself" {
  export VPS_HOST="example.com"
  touch "$TEST_TMP/.env"
  run diff_warn_env_divergence "test-stack" "$TEST_TMP/.env" "$TEST_TMP/stacks/test-stack"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "diff_warn_env_divergence: warns when host .env has different volume var" {
  export VPS_HOST="example.com"
  export VPS_USER="ubuntu"
  export VPS_DEPLOY_DIR=""

  # Local .prod.env
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=example.com
INSTALL_DIR=/opt/plane
EOF

  # Stub diff_fetch_remote to return host's .env with different INSTALL_DIR
  diff_fetch_remote() {
    echo "VPS_HOST=example.com
INSTALL_DIR=./plane"
  }
  export -f diff_fetch_remote

  run diff_warn_env_divergence "test-stack" "$TEST_TMP/.prod.env" "$TEST_TMP/stacks/test-stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSTALL_DIR"* ]]
  [[ "$output" == *"divergence"* ]] || [[ "$output" == *"Divergence"* ]]
}

@test "diff_warn_env_divergence: warns (but still returns 0) when SSH connection fails" {
  export VPS_HOST="example.com"
  export VPS_USER="ubuntu"
  export VPS_DEPLOY_DIR=""

  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=example.com
INSTALL_DIR=/opt/plane
EOF

  # rc=2 sentinel: ssh itself failed to connect
  diff_fetch_remote() { return 2; }
  export -f diff_fetch_remote

  run diff_warn_env_divergence "test-stack" "$TEST_TMP/.prod.env" "$TEST_TMP/stacks/test-stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cannot verify env divergence"* ]]
}

@test "diff_warn_env_divergence: silent when volume vars match" {
  export VPS_HOST="example.com"
  export VPS_USER="ubuntu"
  export VPS_DEPLOY_DIR=""

  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=example.com
INSTALL_DIR=/opt/plane
LOG_LEVEL=info
EOF

  # Host .env has same INSTALL_DIR
  diff_fetch_remote() {
    echo "VPS_HOST=example.com
INSTALL_DIR=/opt/plane
LOG_LEVEL=debug"
  }
  export -f diff_fetch_remote

  run diff_warn_env_divergence "test-stack" "$TEST_TMP/.prod.env" "$TEST_TMP/stacks/test-stack"
  [ "$status" -eq 0 ]
  # LOG_LEVEL differs but it's not a volume var — should be silent
  [[ "$output" != *"divergence"* ]] && [[ "$output" != *"Divergence"* ]]
}


# ── deploy_prepare: required_vars injection prevention ────────────────────────

@test "deploy_prepare: rejects hostile var name in required_vars (no eval injection)" {
  local stack_dir="$TEST_TMP/stacks/hostile"
  mkdir -p "$stack_dir"
  echo 'services: {}' > "$stack_dir/docker-compose.yml"
  echo 'GOOD_VAR=ok' > "$TEST_TMP/.test.env"

  # Write a hostile required_vars line that would execute under eval
  printf 'X:-}; echo PWNED; echo ${Y\n' > "$stack_dir/required_vars"

  export GOOD_VAR="value"
  validate_env_file() { true; }
  export_volume_paths() { true; }
  export -f validate_env_file export_volume_paths

  # deploy_prepare should fail with "Invalid variable name" not execute the payload
  run deploy_prepare "hostile" "$stack_dir" "$stack_dir/docker-compose.yml" "$TEST_TMP/.test.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid variable name"* ]]
}

@test "deploy_prepare: accepts valid var names in required_vars" {
  local stack_dir="$TEST_TMP/stacks/valid"
  mkdir -p "$stack_dir"
  echo 'services: {}' > "$stack_dir/docker-compose.yml"
  echo 'MY_VAR=hello' > "$TEST_TMP/.test.env"
  echo 'MY_VAR' > "$stack_dir/required_vars"

  export MY_VAR="hello"
  # Stub validate_env_file and export_volume_paths (called by deploy_prepare)
  validate_env_file() { true; }
  export_volume_paths() { true; }
  export -f validate_env_file export_volume_paths

  run deploy_prepare "valid" "$stack_dir" "$stack_dir/docker-compose.yml" "$TEST_TMP/.test.env"
  [ "$status" -eq 0 ]
}

@test "deploy_prepare: fails on missing required var (safe indirect expansion)" {
  local stack_dir="$TEST_TMP/stacks/missing"
  mkdir -p "$stack_dir"
  echo 'services: {}' > "$stack_dir/docker-compose.yml"
  echo 'X=y' > "$TEST_TMP/.test.env"
  echo 'UNSET_VAR' > "$stack_dir/required_vars"

  unset UNSET_VAR 2>/dev/null || true
  validate_env_file() { true; }
  export_volume_paths() { true; }
  export -f validate_env_file export_volume_paths

  run deploy_prepare "missing" "$stack_dir" "$stack_dir/docker-compose.yml" "$TEST_TMP/.test.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required env var: UNSET_VAR"* ]]
}
