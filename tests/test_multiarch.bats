#!/usr/bin/env bats
# ==================================================
# tests/test_multiarch.bats — Tests for multi-arch / buildx builds (OSS-262)
# ==================================================
# Run:  bats tests/test_multiarch.bats
# Covers: PLATFORMS validation, _deploy_build_images buildx dispatch,
#         and _deploy_warn_arch_mismatch.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_docker

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/topology.sh"
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

# ── _is_valid_platform_list / services.conf validation ───────────────────────

@test "validate: PLATFORMS with a valid multi-arch list passes" {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/cmd_validate.sh"

  mkdir -p "$TEST_TMP/validate-stack"
  cat > "$TEST_TMP/validate-stack/services.conf" <<'EOF'
BUILD_MODE=local
PLATFORMS=linux/amd64,linux/arm64
API_PORT=8000
EOF

  _val_ok() { echo "OK: $1 $2"; }
  _val_error() { echo "ERROR: $1 $2"; }
  _val_warn() { echo "WARN: $1 $2"; }

  run _validate_services_conf "$TEST_TMP/validate-stack"
  [[ "$output" == *"OK"* ]]
  [[ "$output" != *"ERROR"* ]]
}

@test "validate: PLATFORMS with a single valid platform (with variant) passes" {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/cmd_validate.sh"

  mkdir -p "$TEST_TMP/validate-stack2"
  cat > "$TEST_TMP/validate-stack2/services.conf" <<'EOF'
PLATFORMS=linux/arm/v7
EOF

  _val_ok() { echo "OK: $1 $2"; }
  _val_error() { echo "ERROR: $1 $2"; }
  _val_warn() { echo "WARN: $1 $2"; }

  run _validate_services_conf "$TEST_TMP/validate-stack2"
  [[ "$output" != *"ERROR"* ]]
}

@test "validate: PLATFORMS with garbage is rejected" {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/cmd_validate.sh"

  mkdir -p "$TEST_TMP/validate-bad"
  cat > "$TEST_TMP/validate-bad/services.conf" <<'EOF'
PLATFORMS=not-a-platform
EOF

  _val_ok() { echo "OK: $1 $2"; }
  _val_error() { echo "ERROR: $1 $2"; }
  _val_warn() { echo "WARN: $1 $2"; }

  run _validate_services_conf "$TEST_TMP/validate-bad"
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"PLATFORMS"* ]]
}

@test "validate: PLATFORMS with a trailing empty entry is rejected" {
  source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/cmd_validate.sh"

  mkdir -p "$TEST_TMP/validate-bad2"
  cat > "$TEST_TMP/validate-bad2/services.conf" <<'EOF'
PLATFORMS=linux/amd64,
EOF

  _val_ok() { echo "OK: $1 $2"; }
  _val_error() { echo "ERROR: $1 $2"; }
  _val_warn() { echo "WARN: $1 $2"; }

  run _validate_services_conf "$TEST_TMP/validate-bad2"
  [[ "$output" == *"ERROR"* ]]
}

# ── _deploy_build_images: PLATFORMS unset / matches host → no buildx ─────────

@test "pull_only_stack: PLATFORMS unset falls back to plain compose build" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=local
EOF

  docker() {
    case "$1" in
      compose) echo "DOCKER_COMPOSE $*" ;;
      buildx) echo "UNEXPECTED_BUILDX_CALL $*" >&2; return 1 ;;
      version) echo "linux/amd64" ;;
    esac
  }
  export -f docker

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOCKER_COMPOSE"*"build"* ]]
  [[ "$output" != *"UNEXPECTED_BUILDX_CALL"* ]]
}

@test "pull_only_stack: single PLATFORMS matching host arch falls back to compose build" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=local
PLATFORMS=linux/amd64
EOF

  docker() {
    case "$1" in
      version) echo "linux/amd64" ;;
      compose) echo "DOCKER_COMPOSE $*" ;;
      buildx) echo "UNEXPECTED_BUILDX_CALL $*" >&2; return 1 ;;
    esac
  }
  export -f docker

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOCKER_COMPOSE"*"build"* ]]
  [[ "$output" != *"UNEXPECTED_BUILDX_CALL"* ]]
}

# ── _deploy_build_images: cross-arch single platform → buildx --load ─────────

@test "pull_only_stack: single PLATFORMS different from host arch builds via buildx --load" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=local
PLATFORMS=linux/arm64
EOF

  docker() {
    case "$1" in
      version) echo "linux/amd64" ;;
      buildx)
        if [ "$2" = "version" ]; then return 0; fi
        echo "BUILDX $*"
        ;;
      compose) echo "UNEXPECTED_COMPOSE_BUILD $*" >&2; return 1 ;;
    esac
  }
  export -f docker

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUILDX"*"bake"* ]]
  [[ "$output" == *"*.platform=linux/arm64"* ]]
  [[ "$output" == *"--load"* ]]
  [[ "$output" != *"UNEXPECTED_COMPOSE_BUILD"* ]]
}

# ── _deploy_build_images: multi-arch → buildx --push (requires registry) ─────

@test "pull_only_stack: multi-arch PLATFORMS without a registry fails loudly" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=local
PLATFORMS=linux/amd64,linux/arm64
EOF

  docker() {
    case "$1" in
      version) echo "linux/amd64" ;;
      buildx)
        if [ "$2" = "version" ]; then return 0; fi
        echo "UNEXPECTED_BUILDX_BUILD $*"
        ;;
    esac
  }
  export -f docker

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"--push"* ]] || [[ "$output" == *"registry"* ]]
  [[ "$output" != *"UNEXPECTED_BUILDX_BUILD"* ]]
}

@test "pull_only_stack: multi-arch PLATFORMS with a registry configured pushes a manifest" {
  cat > "$TEST_TMP/stacks/hub/services.conf" <<'EOF'
BUILD_MODE=local
PLATFORMS=linux/amd64,linux/arm64
EOF
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
REGISTRY_TYPE=ghcr
REGISTRY_HOST=ghcr.io/example
EOF

  docker() {
    case "$1" in
      version) echo "linux/amd64" ;;
      buildx)
        if [ "$2" = "version" ]; then return 0; fi
        echo "BUILDX $*"
        ;;
    esac
  }
  export -f docker

  run pull_only_stack "hub" "$TEST_TMP/.prod.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"REGISTRY_LOGIN_CALLED"* ]]
  [[ "$output" == *"BUILDX"*"bake"* ]]
  [[ "$output" == *"*.platform=linux/amd64,linux/arm64"* ]]
  [[ "$output" == *"--push"* ]]
}

# ── _deploy_warn_arch_mismatch ────────────────────────────────────────────────

@test "_deploy_warn_arch_mismatch: warns when declared topology arch is not in PLATFORMS" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
pi = pi@raspi.local ~/.ssh/id_rsa arch=arm64

[stacks]
hub = pi
EOF
  export PROJECT_ROOT="$TEST_TMP"

  run _deploy_warn_arch_mismatch "hub" "linux/amd64"
  [ "$status" -eq 0 ]
  [[ "$output" == *"arm64"* ]]
}

@test "_deploy_warn_arch_mismatch: silent when declared topology arch is covered" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
pi = pi@raspi.local ~/.ssh/id_rsa arch=arm64

[stacks]
hub = pi
EOF
  export PROJECT_ROOT="$TEST_TMP"

  run _deploy_warn_arch_mismatch "hub" "linux/amd64,linux/arm64"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not among"* ]]
}

@test "_deploy_warn_arch_mismatch: silent (no crash) when arch cannot be resolved" {
  export VPS_HOST=""
  run _deploy_warn_arch_mismatch "unmapped-stack" "linux/amd64"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
