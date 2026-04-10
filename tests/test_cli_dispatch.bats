#!/usr/bin/env bats
# ==================================================
# tests/test_cli_dispatch.bats — CLI dispatch & arg parsing tests
# ==================================================
# Run:  bats tests/test_cli_dispatch.bats
# Covers: top-level routing, unknown commands, help, list, stack validation

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
}

# ── Help & usage ──────────────────────────────────────────────────────────────

@test "cli.sh --help exits 0 and shows usage" {
  run bash "$CLI" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"strut CLI"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "cli.sh -h exits 0" {
  run bash "$CLI" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "cli.sh help exits 0" {
  run bash "$CLI" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "cli.sh with no args exits 1 and shows usage" {
  run bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# ── list command ──────────────────────────────────────────────────────────────

@test "cli.sh list shows available stacks header" {
  run bash "$CLI" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Available stacks"* ]]
}

@test "cli.sh --list works as alias" {
  run bash "$CLI" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Available stacks"* ]]
}

@test "cli.sh -l works as alias" {
  run bash "$CLI" -l
  [ "$status" -eq 0 ]
  [[ "$output" == *"Available stacks"* ]]
}

# ── Stack validation ──────────────────────────────────────────────────────────

@test "cli.sh with nonexistent stack fails" {
  run bash "$CLI" nonexistent-stack deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Stack not found"* ]]
}

@test "cli.sh with valid stack but no command fails" {
  # Create a temporary stack so we can test command dispatch
  local cli_root="$(dirname "$CLI")"
  mkdir -p "$cli_root/stacks/test-stack"
  touch "$cli_root/stacks/test-stack/docker-compose.yml"
  run bash "$CLI" test-stack
  rm -rf "$cli_root/stacks/test-stack"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing command"* ]]
}

@test "cli.sh with valid stack and unknown command fails" {
  local cli_root="$(dirname "$CLI")"
  mkdir -p "$cli_root/stacks/test-stack"
  touch "$cli_root/stacks/test-stack/docker-compose.yml"
  run bash "$CLI" test-stack foobar
  rm -rf "$cli_root/stacks/test-stack"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
}

# ── Scaffold validation ──────────────────────────────────────────────────────

@test "cli.sh scaffold with no name fails" {
  run bash "$CLI" scaffold
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "cli.sh scaffold with existing stack fails" {
  local cli_root="$(dirname "$CLI")"
  mkdir -p "$cli_root/stacks/existing-stack"
  run bash "$CLI" scaffold existing-stack
  rm -rf "$cli_root/stacks/existing-stack"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}
