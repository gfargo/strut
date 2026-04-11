#!/usr/bin/env bats
# ==================================================
# tests/test_keys.bats — Tests for key management module
# ==================================================
# Run:  bats tests/test_keys.bats
# Covers: validate_ssh_key_format, validate_api_key_format,
#         ensure_keys_dir, log_key_operation, get_stack_repos

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/keys.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-keys-"*
  rm -rf "$TEST_TMP"
}

# ── validate_ssh_key_format ───────────────────────────────────────────────────

@test "validate_ssh_key_format: accepts ssh-rsa key" {
  echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB user@host" > "$TEST_TMP/id_rsa.pub"
  run validate_ssh_key_format "$TEST_TMP/id_rsa.pub"
  [ "$status" -eq 0 ]
}

@test "validate_ssh_key_format: accepts ssh-ed25519 key" {
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI user@host" > "$TEST_TMP/id_ed25519.pub"
  run validate_ssh_key_format "$TEST_TMP/id_ed25519.pub"
  [ "$status" -eq 0 ]
}

@test "validate_ssh_key_format: accepts ecdsa key" {
  echo "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY user@host" > "$TEST_TMP/id_ecdsa.pub"
  run validate_ssh_key_format "$TEST_TMP/id_ecdsa.pub"
  [ "$status" -eq 0 ]
}

@test "validate_ssh_key_format: rejects non-SSH content" {
  echo "not a valid ssh key" > "$TEST_TMP/bad.pub"
  run validate_ssh_key_format "$TEST_TMP/bad.pub"
  [ "$status" -eq 1 ]
}

@test "validate_ssh_key_format: rejects missing file" {
  run validate_ssh_key_format "$TEST_TMP/nonexistent.pub"
  [ "$status" -eq 1 ]
}

# ── Property: SSH key format validation ───────────────────────────────────────

@test "Property: valid SSH key prefixes accepted, random strings rejected (100 iterations)" {
  local valid_prefixes=("ssh-rsa" "ssh-ed25519" "ssh-dss" "ecdsa-sha2-nistp256" "ecdsa-sha2-nistp384")

  for i in $(seq 1 100); do
    if (( RANDOM % 2 == 0 )); then
      # Generate valid key
      local prefix="${valid_prefixes[$((RANDOM % ${#valid_prefixes[@]}))]}"
      echo "$prefix AAAAB3NzaC1yc2EAAAADAQABAAAB test@host" > "$TEST_TMP/key_$i.pub"
      run validate_ssh_key_format "$TEST_TMP/key_$i.pub"
      [ "$status" -eq 0 ] || {
        echo "FAILED: valid key with prefix '$prefix' rejected"
        return 1
      }
    else
      # Generate invalid key (random string)
      local random_str
      random_str=$(head -c 20 /dev/urandom | base64 | tr -d '/+=' | head -c 15)
      echo "$random_str" > "$TEST_TMP/key_$i.pub"
      run validate_ssh_key_format "$TEST_TMP/key_$i.pub"
      [ "$status" -eq 1 ] || {
        echo "FAILED: random string '$random_str' accepted as valid SSH key"
        return 1
      }
    fi
  done
}

# ── validate_api_key_format ───────────────────────────────────────────────────

@test "validate_api_key_format: accepts 32+ char base64-like string" {
  run validate_api_key_format "abcdefghijklmnopqrstuvwxyz123456"
  [ "$status" -eq 0 ]
}

@test "validate_api_key_format: rejects key with special characters" {
  run validate_api_key_format "sk-proj-abc!@#def"
  [ "$status" -eq 1 ]
}

@test "validate_api_key_format: rejects short string" {
  run validate_api_key_format "short"
  [ "$status" -eq 1 ]
}

@test "validate_api_key_format: rejects empty string" {
  run validate_api_key_format ""
  [ "$status" -eq 1 ]
}

# ── ensure_keys_dir ───────────────────────────────────────────────────────────

@test "ensure_keys_dir: creates directory with metadata files" {
  local stack="test-keys-init-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  run ensure_keys_dir "$stack"
  [ "$status" -eq 0 ]

  local keys_dir="$CLI_ROOT/stacks/$stack/keys"
  [ -d "$keys_dir" ]
  [ -f "$keys_dir/ssh-keys.json" ]
  [ -f "$keys_dir/api-keys.json" ]
  [ -f "$keys_dir/github-secrets.json" ]
  [ -f "$keys_dir/env-vars.json" ]
  [ -f "$keys_dir/key-audit.log" ]
  [ -f "$keys_dir/.gitignore" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "ensure_keys_dir: creates valid JSON metadata files" {
  local stack="test-keys-json-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  ensure_keys_dir "$stack" >/dev/null 2>&1

  local keys_dir="$CLI_ROOT/stacks/$stack/keys"
  jq empty "$keys_dir/ssh-keys.json"
  jq empty "$keys_dir/api-keys.json"
  jq empty "$keys_dir/github-secrets.json"
  jq empty "$keys_dir/env-vars.json"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "ensure_keys_dir: idempotent — second call doesn't break anything" {
  local stack="test-keys-idem-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  ensure_keys_dir "$stack" >/dev/null 2>&1
  ensure_keys_dir "$stack" >/dev/null 2>&1

  local keys_dir="$CLI_ROOT/stacks/$stack/keys"
  jq empty "$keys_dir/ssh-keys.json"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "ensure_keys_dir: repairs missing metadata files" {
  local stack="test-keys-repair-$$"
  local keys_dir="$CLI_ROOT/stacks/$stack/keys"
  mkdir -p "$keys_dir"

  # Create only some files, leave others missing
  echo '{"ssh_keys":[],"last_updated":"2024-01-01T00:00:00Z"}' > "$keys_dir/ssh-keys.json"
  touch "$keys_dir/key-audit.log"

  ensure_keys_dir "$stack" >/dev/null 2>&1

  # Missing files should be recreated
  [ -f "$keys_dir/api-keys.json" ]
  [ -f "$keys_dir/github-secrets.json" ]
  [ -f "$keys_dir/env-vars.json" ]
  jq empty "$keys_dir/api-keys.json"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── log_key_operation ─────────────────────────────────────────────────────────

@test "log_key_operation: appends to audit log" {
  local stack="test-keys-log-$$"
  local keys_dir="$CLI_ROOT/stacks/$stack/keys"
  mkdir -p "$keys_dir"
  touch "$keys_dir/key-audit.log"

  log_key_operation "$stack" "ssh:add" "Added key for alice"
  log_key_operation "$stack" "api:rotate" "Rotated API key"

  local line_count
  line_count=$(wc -l < "$keys_dir/key-audit.log")
  [ "$line_count" -eq 2 ]

  grep -q "ssh:add" "$keys_dir/key-audit.log"
  grep -q "api:rotate" "$keys_dir/key-audit.log"
  grep -q "SUCCESS" "$keys_dir/key-audit.log"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "log_key_operation: records FAILED status with --failed flag" {
  local stack="test-keys-logfail-$$"
  local keys_dir="$CLI_ROOT/stacks/$stack/keys"
  mkdir -p "$keys_dir"
  touch "$keys_dir/key-audit.log"

  log_key_operation "$stack" "ssh:rotate" "Rotation failed" --failed

  grep -q "FAILED" "$keys_dir/key-audit.log"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── get_stack_repos ───────────────────────────────────────────────────────────

@test "get_stack_repos: reads repos from repos.conf" {
  local stack="test-keys-repos-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  cat > "$CLI_ROOT/stacks/$stack/repos.conf" <<'EOF'
# My repos
org/repo-one
org/repo-two
EOF

  run get_stack_repos "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"org/repo-one"* ]]
  [[ "$output" == *"org/repo-two"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_stack_repos: skips comments and empty lines" {
  local stack="test-keys-repos-skip-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  cat > "$CLI_ROOT/stacks/$stack/repos.conf" <<'EOF'
# This is a comment

org/actual-repo

# Another comment
EOF

  run get_stack_repos "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"org/actual-repo"* ]]
  [[ "$output" != *"comment"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_stack_repos: warns when no repos.conf exists" {
  local stack="test-keys-repos-none-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  unset DEFAULT_ORG

  run get_stack_repos "$stack"
  [[ "$output" == *"No repos.conf"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── .gitignore in keys dir ────────────────────────────────────────────────────

@test "ensure_keys_dir: .gitignore blocks secret files but allows metadata" {
  local stack="test-keys-gitignore-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  ensure_keys_dir "$stack" >/dev/null 2>&1

  local gitignore="$CLI_ROOT/stacks/$stack/keys/.gitignore"
  [ -f "$gitignore" ]
  grep -q "*.key" "$gitignore"
  grep -q "*.pem" "$gitignore"
  grep -q "!*.json" "$gitignore"
  grep -q "!key-audit.log" "$gitignore"

  rm -rf "$CLI_ROOT/stacks/$stack"
}
