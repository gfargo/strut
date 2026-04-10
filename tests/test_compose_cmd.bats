#!/usr/bin/env bats
# ==================================================
# tests/test_compose_cmd.bats — Tests for resolve_local_compose_cmd
# ==================================================
# Run:  bats tests/test_compose_cmd.bats

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load() {
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/docker.sh"
  fail() { echo "$1" >&2; return 1; }
}

# ── resolve_local_compose_cmd ─────────────────────────────────────────────────

@test "resolve_local_compose_cmd: uses docker-compose.local.yml when present" {
  _load
  local stack="teststk"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  touch "$CLI_ROOT/stacks/$stack/docker-compose.local.yml"

  result=$(resolve_local_compose_cmd "$stack")
  [[ "$result" == *"docker-compose.local.yml"* ]]

  rm -f "$CLI_ROOT/stacks/$stack/docker-compose.local.yml"
  rmdir "$CLI_ROOT/stacks/$stack" 2>/dev/null || true
}

@test "resolve_local_compose_cmd: falls back to docker-compose.yml" {
  _load
  local stack="teststk-fallback"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  touch "$CLI_ROOT/stacks/$stack/docker-compose.yml"
  # No docker-compose.local.yml — should fall back

  result=$(resolve_local_compose_cmd "$stack")
  [[ "$result" == *"docker-compose.yml"* ]]
  [[ "$result" != *"docker-compose.local.yml"* ]]

  rm -f "$CLI_ROOT/stacks/$stack/docker-compose.yml"
  rmdir "$CLI_ROOT/stacks/$stack" 2>/dev/null || true
}

@test "resolve_local_compose_cmd: includes --env-file when .env.local exists" {
  _load
  local stack="teststk2"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  touch "$CLI_ROOT/stacks/$stack/docker-compose.yml"
  touch "$CLI_ROOT/stacks/$stack/.env.local"

  result=$(resolve_local_compose_cmd "$stack")
  [[ "$result" == *"--env-file"* ]]
  [[ "$result" == *".env.local"* ]]

  rm -f "$CLI_ROOT/stacks/$stack/docker-compose.yml" "$CLI_ROOT/stacks/$stack/.env.local"
  rmdir "$CLI_ROOT/stacks/$stack" 2>/dev/null || true
}

@test "resolve_local_compose_cmd: no --env-file when .env.local missing" {
  _load
  local stack="knowledge-graph"
  # Remove .env.local if it exists for this test
  local env_local="$CLI_ROOT/stacks/$stack/.env.local"
  if [ ! -f "$env_local" ]; then
    result=$(resolve_local_compose_cmd "$stack")
    [[ "$result" != *"--env-file"* ]]
  else
    skip ".env.local exists in knowledge-graph"
  fi
}

@test "resolve_local_compose_cmd: includes --profile when specified" {
  _load
  local stack="knowledge-graph"
  result=$(resolve_local_compose_cmd "$stack" "full")
  [[ "$result" == *"--profile full"* ]]
}

@test "resolve_local_compose_cmd: no --profile when empty" {
  _load
  local stack="knowledge-graph"
  result=$(resolve_local_compose_cmd "$stack" "")
  [[ "$result" != *"--profile"* ]]
}
