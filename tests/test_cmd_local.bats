#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_local.bats — Tests for local/prod/staging command routing
# ==================================================
# Run:  bats tests/test_cmd_local.bats
# Covers: CLI-317 — per-command arg parsing for local/prod/staging/dev

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  # Create a minimal test stack so the CLI doesn't fail on "Stack not found"
  TEST_STACK="test-local-stack"
  mkdir -p "$CLI_ROOT/stacks/$TEST_STACK"
  echo "services:" > "$CLI_ROOT/stacks/$TEST_STACK/docker-compose.yml"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/$TEST_STACK"
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# ── Guard: dev commands only work with 'local' prefix ─────────────────────────

@test "strut: 'local start' doesn't fail with stack-not-found" {
  # Pipe empty stdin to avoid interactive prompts
  run bash -c "echo n | bash '$CLI' $TEST_STACK local start"
  # Should NOT say "Unknown command"
  [[ "$output" != *"Unknown command"* ]]
}

@test "strut: 'prod start' fails — dev commands only work with local" {
  run bash "$CLI" $TEST_STACK prod start
  [ "$status" -ne 0 ]
  [[ "$output" == *"only work with 'local'"* ]] || [[ "$output" == *"not found"* ]]
}

@test "strut: 'staging stop' fails — dev commands only work with local" {
  run bash "$CLI" $TEST_STACK staging stop
  [ "$status" -ne 0 ]
}

@test "strut: 'local badcmd' fails with unknown command" {
  run bash "$CLI" $TEST_STACK local badcmd
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]] || [[ "$output" == *"unknown"* ]] || [[ "$output" == *"not found"* ]]
}

# ── Verify all valid local subcommands are recognized ─────────────────────────

@test "strut: 'local stop' is a recognized command" {
  # Pipe empty stdin to avoid interactive prompts; may fail on docker but not routing
  run bash -c "echo n | bash '$CLI' $TEST_STACK local stop"
  [[ "$output" != *"Unknown command"* ]]
  [[ "$output" != *"Unknown local command"* ]]
}

@test "strut: 'local reset' is a recognized command" {
  # Pipe 'no' to avoid confirm() prompt
  run bash -c "echo no | bash '$CLI' $TEST_STACK local reset"
  [[ "$output" != *"Unknown command"* ]]
  [[ "$output" != *"Unknown local command"* ]]
}

@test "strut: 'local sync-env' without --from fails with usage" {
  run bash "$CLI" $TEST_STACK local sync-env
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from"* ]]
}

@test "strut: 'local sync-db' without --from fails with usage" {
  run bash "$CLI" $TEST_STACK local sync-db
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from"* ]]
}
