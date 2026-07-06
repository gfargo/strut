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

# ── docker_require_images ────────────────────────────────────────────────────
# Regression coverage for the python-api recipe deploy hang: a service with
# both `build:` and `image:` set (build locally, tag for later push) must
# not be treated as a failed registry pull just because its image hasn't
# been built yet — `up` builds it. Only a genuinely missing, non-buildable
# image should abort the deploy.

@test "docker_require_images: build-backed image missing locally is not fatal" {
  _load_docker
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  docker() {
    case "$*" in
      *"config --images"*)
        printf '%s\n' "org/app-api:latest" "postgres:16-alpine"
        ;;
      *"config --format json"*)
        echo '{"services":{"api":{"build":{"context":"./app"},"image":"org/app-api:latest"},"postgres":{"image":"postgres:16-alpine"}}}'
        ;;
      *"image inspect org/app-api:latest"*) return 1 ;;
      *"image inspect postgres:16-alpine"*) return 0 ;;
      *) return 0 ;;
    esac
  }

  run docker_require_images "docker compose -f x.yml"
  [ "$status" -eq 0 ]
}

@test "docker_require_images: registry-only image missing locally is fatal" {
  _load_docker
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  docker() {
    case "$*" in
      *"config --images"*) echo "org/app-api:latest" ;;
      *"config --format json"*)
        echo '{"services":{"api":{"image":"org/app-api:latest"}}}'
        ;;
      *"image inspect"*) return 1 ;;
      *) return 0 ;;
    esac
  }

  run docker_require_images "docker compose -f x.yml"
  [ "$status" -eq 1 ]
}
