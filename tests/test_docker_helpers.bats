#!/usr/bin/env bats
# ==================================================
# tests/test_docker_helpers.bats — Tests for lib/docker.sh helpers
# ==================================================
# Run:  bats tests/test_docker_helpers.bats
# Covers: _docker_sudo, docker_require_images

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLI_ROOT
}

_load_docker() {
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/docker.sh"
  fail() { echo "$1" >&2; return 1; }
}

# ── _docker_sudo ──────────────────────────────────────────────────────────────

@test "_docker_sudo: returns 'sudo ' when VPS_SUDO=true" {
  _load_docker
  VPS_SUDO=true
  result=$(_docker_sudo)
  [ "$result" = "sudo " ]
}

@test "_docker_sudo: returns empty when VPS_SUDO=false" {
  _load_docker
  VPS_SUDO=false
  result=$(_docker_sudo)
  [ -z "$result" ]
}

@test "_docker_sudo: returns empty when VPS_SUDO unset" {
  _load_docker
  unset VPS_SUDO
  result=$(_docker_sudo)
  [ -z "$result" ]
}

@test "_docker_sudo: returns empty for random VPS_SUDO value" {
  _load_docker
  VPS_SUDO=yes
  result=$(_docker_sudo)
  [ -z "$result" ]
}

# ── docker_require_images ─────────────────────────────────────────────────────
# Regression coverage for the mixed pull+build case (e.g. a recipe that pulls
# postgres from a registry but builds its own app image from a local
# Dockerfile) — the pre-teardown check must not treat a never-pulled,
# locally-built image as a failed pull.

_fake_compose() {
  # _fake_compose <name> <images_output> <json_output>
  local script="$TEST_TMP/$1"
  cat > "$script" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "config" ] && [ "\$2" = "--images" ]; then
  cat <<'IMAGES'
$2
IMAGES
elif [ "\$1" = "config" ] && [ "\$2" = "--format" ]; then
  cat <<'JSON'
$3
JSON
fi
EOF
  chmod +x "$script"
  echo "$script"
}

setup_require_images() {
  _load_docker
  TEST_TMP="$(mktemp -d)"
}

teardown_require_images() { rm -rf "$TEST_TMP"; }

@test "docker_require_images: passes when a build-only image was never pulled (jq present)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  setup_require_images

  local images=$'org/app-api:latest\npostgres:16-alpine'
  local json='{"services":{"api":{"build":".","image":"org/app-api:latest"},"postgres":{"image":"postgres:16-alpine"}}}'
  local compose_cmd; compose_cmd="$(_fake_compose fake-compose "$images" "$json")"

  # api's image was only ever built, never pulled — it must NOT be present
  # locally; postgres was pulled successfully.
  docker() {
    [ "$1" = "image" ] && [ "$2" = "inspect" ] || return 1
    [ "$3" = "postgres:16-alpine" ]
  }
  export -f docker

  run docker_require_images "$compose_cmd"
  [ "$status" -eq 0 ]

  teardown_require_images
}

@test "docker_require_images: fails when a registry-only image is missing after pull" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  setup_require_images

  local images=$'org/app-api:latest\npostgres:16-alpine'
  local json='{"services":{"api":{"build":".","image":"org/app-api:latest"},"postgres":{"image":"postgres:16-alpine"}}}'
  local compose_cmd; compose_cmd="$(_fake_compose fake-compose "$images" "$json")"

  # Neither image present locally — postgres has no build directive, so its
  # absence is a real failed pull.
  docker() { return 1; }
  export -f docker

  run docker_require_images "$compose_cmd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"postgres:16-alpine"* ]]
  [[ "$output" != *"org/app-api:latest"* ]]

  teardown_require_images
}

@test "docker_require_images: passes when every image is present locally" {
  setup_require_images

  local images=$'org/app-api:latest\npostgres:16-alpine'
  local compose_cmd; compose_cmd="$(_fake_compose fake-compose "$images" "{}")"

  docker() { [ "$1" = "image" ] && [ "$2" = "inspect" ]; }
  export -f docker

  run docker_require_images "$compose_cmd"
  [ "$status" -eq 0 ]

  teardown_require_images
}

@test "docker_require_images: without jq, falls back to checking every image" {
  setup_require_images

  local images="postgres:16-alpine"
  local compose_cmd; compose_cmd="$(_fake_compose fake-compose "$images" "{}")"

  # Simulate a jq-less host: intercept only "command -v jq", pass everything
  # else through to the real builtin.
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "jq" ]; then return 1; fi
    builtin command "$@"
  }
  docker() { return 1; }
  export -f docker

  run docker_require_images "$compose_cmd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"postgres:16-alpine"* ]]
  [[ "$output" == *"jq not found"* ]]

  teardown_require_images
}
