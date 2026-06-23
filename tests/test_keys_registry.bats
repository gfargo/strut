#!/usr/bin/env bats
# ==================================================
# tests/test_keys_registry.bats — Registry credential management tests
# ==================================================
# Run:  bats tests/test_keys_registry.bats
# Covers: _registry_host_list, keys_registry_rotate (dry-run/validation),
#         keys_registry_status (no-host/json), metadata file operations

setup() {
  export CLI_ROOT
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  # Override fail() so it returns rather than exits — allows testing error paths
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/keys.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-reg-"*
  rm -rf "$TEST_TMP"
}

# ── _registry_host_list ───────────────────────────────────────────────────────

@test "_registry_host_list: returns VPS_HOST when override is 'all'" {
  run _registry_host_list "myhost.example.com" "all"
  [ "$status" -eq 0 ]
  [ "$output" = "myhost.example.com" ]
}

@test "_registry_host_list: returns VPS_HOST when override is empty" {
  run _registry_host_list "myhost.example.com" ""
  [ "$status" -eq 0 ]
  [ "$output" = "myhost.example.com" ]
}

@test "_registry_host_list: expands comma-separated explicit host list" {
  run _registry_host_list "default.example.com" "host1.com,host2.com,host3.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"host1.com"* ]]
  [[ "$output" == *"host2.com"* ]]
  [[ "$output" == *"host3.com"* ]]
}

@test "_registry_host_list: single explicit host overrides VPS_HOST" {
  run _registry_host_list "default.example.com" "override.example.com"
  [ "$status" -eq 0 ]
  [ "$output" = "override.example.com" ]
  [[ "$output" != *"default"* ]]
}

@test "_registry_host_list: produces no output when vps_host empty and override is 'all'" {
  run _registry_host_list "" "all"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_registry_host_list: one line per explicit host" {
  local result
  result=$(_registry_host_list "" "alpha.com,beta.com")
  local line_count
  line_count=$(echo "$result" | wc -l)
  [ "$line_count" -eq 2 ]
}

# ── keys_registry_rotate: early validation ────────────────────────────────────

@test "keys_registry_rotate: fails when registry username is not configured" {
  local stack="test-reg-nouser-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/no_user.env"
  printf 'VPS_HOST=myhost.example.com\n' > "$env_file"

  run keys_registry_rotate "$stack" --dry-run --env-file "$env_file"
  [ "$status" -ne 0 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "keys_registry_rotate: fails when no hosts are configured" {
  local stack="test-reg-nohost-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/no_host.env"
  printf 'GHCR_USER=myuser\n' > "$env_file"

  run keys_registry_rotate "$stack" --dry-run --env-file "$env_file"
  [ "$status" -ne 0 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "keys_registry_rotate: --username flag satisfies username requirement" {
  local stack="test-reg-userflag-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/userflag.env"
  printf 'VPS_HOST=myhost.example.com\n' > "$env_file"

  run keys_registry_rotate "$stack" \
    --dry-run \
    --username "myuser" \
    --env-file "$env_file"
  [ "$status" -eq 0 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── keys_registry_rotate: dry-run output ─────────────────────────────────────

@test "keys_registry_rotate: dry-run shows DRY RUN marker" {
  local stack="test-reg-dry-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/dry.env"
  printf 'VPS_HOST=myhost.example.com\nGHCR_USER=myuser\n' > "$env_file"

  run keys_registry_rotate "$stack" \
    --dry-run \
    --env-file "$env_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "keys_registry_rotate: dry-run shows registry and username" {
  local stack="test-reg-dryinfo-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/dryinfo.env"
  printf 'VPS_HOST=myhost.example.com\nGHCR_USER=myuser\n' > "$env_file"

  run keys_registry_rotate "$stack" \
    --dry-run \
    --registry "ghcr.io" \
    --env-file "$env_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io"* ]]
  [[ "$output" == *"myuser"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "keys_registry_rotate: dry-run with custom --hosts shows those hosts" {
  local stack="test-reg-dryhosts-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/dryhosts.env"
  printf 'GHCR_USER=myuser\n' > "$env_file"

  run keys_registry_rotate "$stack" \
    --dry-run \
    --hosts "host1.com,host2.com" \
    --env-file "$env_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"host1.com"* ]]
  [[ "$output" == *"host2.com"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "keys_registry_rotate: dry-run with --revoke-old mentions revoke guidance" {
  local stack="test-reg-dryrevoke-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/dryrevoke.env"
  printf 'VPS_HOST=myhost.example.com\nGHCR_USER=myuser\n' > "$env_file"

  run keys_registry_rotate "$stack" \
    --dry-run \
    --revoke-old \
    --env-file "$env_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"revoke"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "keys_registry_rotate: reads username from GITHUB_USER env var" {
  local stack="test-reg-ghuser-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/ghuser.env"
  printf 'VPS_HOST=myhost.example.com\nGITHUB_USER=ghuser\n' > "$env_file"

  run keys_registry_rotate "$stack" \
    --dry-run \
    --env-file "$env_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghuser"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── keys_registry_status: no-host / error paths ──────────────────────────────

@test "keys_registry_status: warns and returns error when no hosts configured" {
  local stack="test-reg-stat-nohost-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/stat_nohost.env"
  printf '# no VPS_HOST\n' > "$env_file"

  run keys_registry_status "$stack" --env-file "$env_file"
  [ "$status" -ne 0 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "keys_registry_status: --json returns error object when no hosts configured" {
  local stack="test-reg-stat-json-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/stat_json.env"
  printf '# no VPS_HOST\n' > "$env_file"

  run keys_registry_status "$stack" --json --env-file "$env_file"
  [ "$status" -ne 0 ]
  # Output should contain an error key
  [[ "$output" == *'"error"'* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── registry-credentials.json metadata ───────────────────────────────────────

@test "registry-credentials.json: initialized with correct structure on first rotate (dry-run skips file creation)" {
  local stack="test-reg-meta-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  local env_file="$TEST_TMP/meta.env"
  printf 'VPS_HOST=myhost.example.com\nGHCR_USER=myuser\n' > "$env_file"

  # dry-run should not create the metadata file
  keys_registry_rotate "$stack" --dry-run --env-file "$env_file" >/dev/null 2>&1
  local meta_file="$CLI_ROOT/stacks/$stack/keys/registry-credentials.json"
  [ ! -f "$meta_file" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── Property: host list expansion is stable ───────────────────────────────────

@test "Property: _registry_host_list output line count matches explicit host count (10 iterations)" {
  for n in 1 2 3 4 5 6 7 8 9 10; do
    # Build a comma-separated list of n hosts
    local hosts
    hosts=$(seq 1 "$n" | sed 's/.*/host&.example.com/' | paste -sd ',' -)
    local actual_count
    actual_count=$(_registry_host_list "" "$hosts" | wc -l | tr -d ' ')
    [ "$actual_count" -eq "$n" ] || {
      echo "FAILED: expected $n hosts, got $actual_count for input: $hosts"
      return 1
    }
  done
}
