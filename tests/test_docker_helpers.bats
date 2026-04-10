#!/usr/bin/env bats
# ==================================================
# tests/test_docker_helpers.bats — Tests for lib/docker.sh helpers
# ==================================================
# Run:  bats tests/test_docker_helpers.bats
# Covers: _docker_sudo

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
