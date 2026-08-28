#!/usr/bin/env bats
# ==================================================
# tests/test_keys_status.bats — Tests for lib/keys/status.sh and lib/keys/discovery.sh
# ==================================================
# Run:  bats tests/test_keys_status.bats
# Covers:
#   keys_status — --json output shape (ssh_keys/api_keys/vps_status keys),
#                  text output, counts from fixture JSON files
#   keys_recent — --limit slicing from a seeded audit log
#   discover_local_keys — env file and SSH key enumeration from fixtures
#   generate_recommendations — recommendation strings for known inputs

setup() {
  export CLI_ROOT
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  STACK="test-keys-status-$$"
  mkdir -p "$CLI_ROOT/stacks/$STACK"

  source "$CLI_ROOT/lib/utils.sh"
  fail()  { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn()  { echo "$1" >&2; }
  ok()    { echo "$1"; }
  log()   { echo "$1"; }

  # Source the full keys module (includes status.sh, discovery.sh, pull.sh, etc.)
  source "$CLI_ROOT/lib/keys.sh"

  # Stub network helpers — tests never touch a real host
  validate_vps_connection() { return 1; }  # default: unreachable (overridden per test)
  export -f validate_vps_connection

  build_ssh_opts() { echo ""; }
  export -f build_ssh_opts

  resolve_deploy_dir() { echo "/opt/deploy"; }
  export -f resolve_deploy_dir

  # Keys metadata directory
  KEYS_DIR="$CLI_ROOT/stacks/$STACK/keys"
  ensure_keys_dir "$STACK"

  # Seed minimal JSON fixtures
  printf '{"ssh_keys":[{"username":"alice"},{"username":"bob"}]}\n' \
    > "$KEYS_DIR/ssh-keys.json"
  printf '{"api_keys":[{"name":"mykey"}]}\n' \
    > "$KEYS_DIR/api-keys.json"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/$STACK"
  rm -f "$CLI_ROOT/.prod.env"
  rm -rf "$TEST_TMP"
}

# ── keys_status --json: output shape ─────────────────────────────────────────

@test "keys_status --json: emits valid JSON (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'VPS_HOST=\nVPS_USER=ubuntu\n' > "$CLI_ROOT/.prod.env"

  run keys_status "$STACK" --json
  [ "$status" -eq 0 ]
  run jq -e '.' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "keys_status --json: contains required top-level keys (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'VPS_HOST=\nVPS_USER=ubuntu\n' > "$CLI_ROOT/.prod.env"

  run keys_status "$STACK" --json
  [ "$status" -eq 0 ]
  run jq -e '.ssh_keys' <<< "$output"
  [ "$status" -eq 0 ]
  run jq -e '.api_keys' <<< "$output"
  [ "$status" -eq 0 ]
  run jq -e '.vps_status' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "keys_status --json: ssh_keys count reflects fixture (2 keys) (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'VPS_HOST=\n' > "$CLI_ROOT/.prod.env"

  run keys_status "$STACK" --json
  [ "$status" -eq 0 ]
  local count
  count=$(jq -r '.ssh_keys' <<< "$output")
  [ "$count" -eq 2 ]
}

@test "keys_status --json: api_keys count reflects fixture (1 key) (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'VPS_HOST=\n' > "$CLI_ROOT/.prod.env"

  run keys_status "$STACK" --json
  [ "$status" -eq 0 ]
  local count
  count=$(jq -r '.api_keys' <<< "$output")
  [ "$count" -eq 1 ]
}

@test "keys_status --json: vps_status is 'unknown' when VPS_HOST is empty (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'VPS_HOST=\nVPS_USER=ubuntu\n' > "$CLI_ROOT/.prod.env"

  run keys_status "$STACK" --json
  [ "$status" -eq 0 ]
  local status_val
  status_val=$(jq -r '.vps_status' <<< "$output")
  [ "$status_val" = "unknown" ]
}

@test "keys_status --json: vps_status is 'unreachable' when connection fails (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'VPS_HOST=fakehost\nVPS_USER=ubuntu\n' > "$CLI_ROOT/.prod.env"
  validate_vps_connection() { return 1; }
  export -f validate_vps_connection

  run keys_status "$STACK" --json
  [ "$status" -eq 0 ]
  local status_val
  status_val=$(jq -r '.vps_status' <<< "$output")
  [ "$status_val" = "unreachable" ]
}

@test "keys_status --json: vps_status is 'connected' when connection succeeds (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'VPS_HOST=fakehost\nVPS_USER=ubuntu\n' > "$CLI_ROOT/.prod.env"
  validate_vps_connection() { return 0; }
  export -f validate_vps_connection

  run keys_status "$STACK" --json
  [ "$status" -eq 0 ]
  local status_val
  status_val=$(jq -r '.vps_status' <<< "$output")
  [ "$status_val" = "connected" ]
}

@test "keys_status --json: env_vars count reflects .prod.env contents (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'FOO=1\nBAR=2\nBAZ=3\n' > "$CLI_ROOT/.prod.env"

  run keys_status "$STACK" --json
  [ "$status" -eq 0 ]
  local env_count
  env_count=$(jq -r '.env_vars' <<< "$output")
  [ "$env_count" -eq 3 ]
}

# ── keys_status text output ───────────────────────────────────────────────────

@test "keys_status text: exits 0 and produces non-empty output" {
  printf 'VPS_HOST=\n' > "$CLI_ROOT/.prod.env"

  run keys_status "$STACK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "keys_status text: mentions SSH key count" {
  printf 'VPS_HOST=\n' > "$CLI_ROOT/.prod.env"

  run keys_status "$STACK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH Keys"* ]] || [[ "$output" == *"ssh_keys"* ]]
}

# ── keys_recent: audit log slicing ───────────────────────────────────────────

@test "keys_recent: returns 1 when no audit log exists" {
  run keys_recent "$STACK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No audit log"* ]]
}

@test "keys_recent: shows all entries when log has fewer than the limit" {
  local audit_log="$KEYS_DIR/key-audit.log"
  printf '[2026-01-01T10:00:00Z] alice: add - added deploy key\n' > "$audit_log"
  printf '[2026-01-02T11:00:00Z] bob: rotate - rotated api key\n' >> "$audit_log"

  run keys_recent "$STACK" --limit 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"bob"* ]]
}

@test "keys_recent: --limit 1 returns only the last entry" {
  local audit_log="$KEYS_DIR/key-audit.log"
  printf '[2026-01-01T10:00:00Z] alice: add - added deploy key\n' > "$audit_log"
  printf '[2026-01-02T11:00:00Z] bob: rotate - rotated api key\n' >> "$audit_log"
  printf '[2026-01-03T12:00:00Z] carol: revoke - revoked old key\n' >> "$audit_log"

  run keys_recent "$STACK" --limit 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"carol"* ]]
  [[ "$output" != *"alice"* ]]
}

@test "keys_recent: --limit=N form (equals sign) also works" {
  local audit_log="$KEYS_DIR/key-audit.log"
  printf '[2026-01-01T10:00:00Z] alice: add - added deploy key\n' > "$audit_log"
  printf '[2026-01-02T11:00:00Z] bob: rotate - rotated api key\n' >> "$audit_log"

  run keys_recent "$STACK" --limit=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"bob"* ]]
  [[ "$output" != *"alice"* ]]
}

# ── discover_local_keys ───────────────────────────────────────────────────────

@test "discover_local_keys: returns valid JSON (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  # Stack has no .env.template; function should still succeed
  run discover_local_keys "$STACK"
  [ "$status" -eq 0 ]
  run jq -e '.' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "discover_local_keys: detects .prod.env presence (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  printf 'KEY=val\n' > "$CLI_ROOT/.prod.env"

  run discover_local_keys "$STACK"
  [ "$status" -eq 0 ]
  # env_files array should contain .prod.env
  run jq -e '.env_files | map(select(. == ".prod.env")) | length > 0' <<< "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == "true" ]]
}

@test "discover_local_keys: template_secrets reflects .env.template line count (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  mkdir -p "$CLI_ROOT/stacks/$STACK"
  printf 'SECRET_A=\nSECRET_B=\nSECRET_C=\n' > "$CLI_ROOT/stacks/$STACK/.env.template"

  run discover_local_keys "$STACK"
  [ "$status" -eq 0 ]
  local count
  count=$(jq -r '.template_secrets' <<< "$output")
  [ "$count" -eq 3 ]
}

@test "discover_local_keys: template_secrets is 0 when no .env.template (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  rm -f "$CLI_ROOT/stacks/$STACK/.env.template"

  run discover_local_keys "$STACK"
  [ "$status" -eq 0 ]
  local count
  count=$(jq -r '.template_secrets' <<< "$output")
  [ "$count" -eq 0 ]
}

# ── generate_recommendations ─────────────────────────────────────────────────

@test "generate_recommendations: returns JSON array (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  local input
  input=$(jq -n '{
    sources: {
      vps: { ssh_keys: 3 },
      github: { repos_scanned: 2, secrets_found: {} },
      local: { env_files: ["a","b"], template_secrets: 5 }
    }
  }')

  run generate_recommendations "$input"
  [ "$status" -eq 0 ]
  run jq -e '. | type == "array"' <<< "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == "true" ]]
}

@test "generate_recommendations: recommends SSH key rotation when VPS has keys (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  local input
  input=$(jq -n '{
    sources: {
      vps: { ssh_keys: 4 },
      github: { repos_scanned: 0, secrets_found: {} },
      local: { env_files: [], template_secrets: 0 }
    }
  }')

  run generate_recommendations "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH"* ]] || [[ "$output" == *"VPS SSH"* ]]
}

@test "generate_recommendations: recommends GitHub review when repos scanned (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  local input
  input=$(jq -n '{
    sources: {
      vps: { ssh_keys: 0 },
      github: { repos_scanned: 3, secrets_found: {} },
      local: { env_files: [], template_secrets: 0 }
    }
  }')

  run generate_recommendations "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub"* ]] || [[ "$output" == *"github"* ]]
}

@test "generate_recommendations: flags large secret count in template (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  local input
  input=$(jq -n '{
    sources: {
      vps: { ssh_keys: 0 },
      github: { repos_scanned: 0, secrets_found: {} },
      local: { env_files: [], template_secrets: 25 }
    }
  }')

  run generate_recommendations "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"25"* ]] || [[ "$output" == *"secret"* ]] || [[ "$output" == *"large"* ]]
}

@test "generate_recommendations: returns empty array for bare minimum input (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  local input
  input=$(jq -n '{
    sources: {
      vps: { ssh_keys: 0 },
      github: { repos_scanned: 0, secrets_found: {} },
      local: { env_files: [], template_secrets: 0 }
    }
  }')

  run generate_recommendations "$input"
  [ "$status" -eq 0 ]
  local arr_len
  arr_len=$(jq '. | length' <<< "$output")
  [ "$arr_len" -eq 0 ]
}
