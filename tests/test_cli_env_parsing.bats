#!/usr/bin/env bats
# ==================================================
# tests/test_cli_env_parsing.bats — Tests for --env flag parsing
# ==================================================
# Run:  bats tests/test_cli_env_parsing.bats
# Covers: CLI-317 — per-command arg parsing, --env resolution

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Create a minimal test stack
  TEST_STACK="test-env-stack"
  mkdir -p "$CLI_ROOT/stacks/$TEST_STACK"
  echo "services:" > "$CLI_ROOT/stacks/$TEST_STACK/docker-compose.yml"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/$TEST_STACK"
}

# These tests verify that --env is parsed correctly at the global level
# and that commands that need env files fail gracefully when the file is missing.

@test "strut: --env prod resolves to .prod.env (fails gracefully if missing vars)" {
  # The deploy command should attempt to use .prod.env
  # It will fail because it needs VPS_HOST, but the error should reference the env file
  run bash "$CLI" $TEST_STACK status --env nonexistent-env-name
  [ "$status" -ne 0 ]
  [[ "$output" == *"Env file not found"* ]] || [[ "$output" == *"not found"* ]]
}

@test "strut: --env=prod (equals syntax) works" {
  run bash "$CLI" $TEST_STACK status --env=nonexistent-env-name
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "strut: commands without --env use default .env" {
  # Without --env, should try to use .env in CLI_ROOT
  # This tests that the default path resolution works
  run bash "$CLI" $TEST_STACK status
  # May succeed or fail depending on .env contents, but should NOT error about missing --env
  [[ "$output" != *"Missing --env"* ]]
}

# ── Verify --env is passed through to commands ────────────────────────────────

@test "strut: deploy with bad --env fails with env file error" {
  run bash "$CLI" $TEST_STACK deploy --env does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "strut: update with bad --env fails with env file error" {
  run bash "$CLI" $TEST_STACK update --env does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "strut: shell with bad --env fails with env file error" {
  run bash "$CLI" $TEST_STACK shell --env does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "strut: db:pull with bad --env fails with env file error" {
  run bash "$CLI" $TEST_STACK db:pull --env does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "strut: db:push with bad --env fails with env file error" {
  run bash "$CLI" $TEST_STACK db:push --env does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ── Regression: env file must be safely parsed, not `source`d (P0 audit finding) ──

@test "strut: env value with a bare space does not crash the dispatcher (exit 127)" {
  echo 'MSG=hello world' > "$CLI_ROOT/.prod.env"
  echo 'VPS_HOST=example.invalid' >> "$CLI_ROOT/.prod.env"
  run bash "$CLI" $TEST_STACK status --env prod
  rm -f "$CLI_ROOT/.prod.env"
  # A `source`d file would die with exit 127 ("world: command not found")
  # before any of strut's own logic runs. It must instead proceed into
  # strut's normal (SSH-failure) error path.
  [ "$status" -ne 127 ]
}

@test "strut: env value with command substitution is not executed" {
  local marker="$CLI_ROOT/.pwned-marker"
  rm -f "$marker"
  {
    echo "VPS_HOST=example.invalid"
    echo "EVIL=\$(touch $marker)"
  } > "$CLI_ROOT/.prod.env"
  run bash "$CLI" $TEST_STACK status --env prod
  rm -f "$CLI_ROOT/.prod.env"
  [ ! -f "$marker" ]
  rm -f "$marker"
}
