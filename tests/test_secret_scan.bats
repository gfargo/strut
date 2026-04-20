#!/usr/bin/env bats
# ==================================================
# tests/test_secret_scan.bats — Tests for secret scanning
# ==================================================
# Run:  bats tests/test_secret_scan.bats
# Covers: _is_secret_pattern, _is_weak_password, _validate_secrets

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/cmd_validate.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── _is_secret_pattern ────────────────────────────────────────────────────────

@test "detects GitHub PAT (ghp_)" {
  run _is_secret_pattern "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub"* ]]
}

@test "detects GitHub fine-grained PAT" {
  run _is_secret_pattern "github_pat_11ABCDEF_abcdefghijklmnop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub"* ]]
}

@test "detects AWS access key" {
  run _is_secret_pattern "AKIAIOSFODNN7EXAMPLE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AWS"* ]]
}

@test "detects sk- API key" {
  run _is_secret_pattern "sk-proj1234567890abcdefghij"
  [ "$status" -eq 0 ]
  [[ "$output" == *"secret key"* ]]
}

@test "detects Slack webhook" {
  run _is_secret_pattern "https://hooks.slack.com/services/T00/B00/xxxx"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack"* ]]
}

@test "ignores normal values" {
  run _is_secret_pattern "my-app-name"
  [ "$status" -eq 1 ]
}

@test "ignores empty string" {
  run _is_secret_pattern ""
  [ "$status" -eq 1 ]
}

@test "ignores numeric values" {
  run _is_secret_pattern "8000"
  [ "$status" -eq 1 ]
}

# ── _is_weak_password ─────────────────────────────────────────────────────────

@test "detects 'password'" {
  run _is_weak_password "password"
  [ "$status" -eq 0 ]
}

@test "detects 'changeme'" {
  run _is_weak_password "changeme"
  [ "$status" -eq 0 ]
}

@test "detects 'change-me'" {
  run _is_weak_password "change-me"
  [ "$status" -eq 0 ]
}

@test "detects 'secret'" {
  run _is_weak_password "secret"
  [ "$status" -eq 0 ]
}

@test "detects case-insensitive 'PASSWORD'" {
  run _is_weak_password "PASSWORD"
  [ "$status" -eq 0 ]
}

@test "accepts strong password" {
  run _is_weak_password "xK9#mP2vL8qR4nW6"
  [ "$status" -eq 1 ]
}

@test "accepts UUID-like password" {
  run _is_weak_password "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  [ "$status" -eq 1 ]
}

# ── _validate_secrets integration ─────────────────────────────────────────────

@test "validate_secrets: warns on weak password in env file" {
  cat > "$TEST_TMP/test.env" <<'EOF'
POSTGRES_PASSWORD=changeme
API_SECRET_KEY=password
EOF

  _VALIDATE_ERRORS=0
  _VALIDATE_WARNINGS=0
  _DOC_JSON=false 2>/dev/null || true

  run _validate_secrets "$TEST_TMP" "$TEST_TMP/test.env"
  [[ "$output" == *"weak"* ]] || [[ "$output" == *"placeholder"* ]]
}

@test "validate_secrets: clean env file shows no issues" {
  cat > "$TEST_TMP/test.env" <<'EOF'
POSTGRES_DB=myapp
API_PORT=8000
VPS_HOST=10.0.0.1
EOF

  _VALIDATE_ERRORS=0
  _VALIDATE_WARNINGS=0

  run _validate_secrets "$TEST_TMP" "$TEST_TMP/test.env"
  [[ "$output" == *"no issues"* ]]
}

# ── Property: known secret patterns always detected ───────────────────────────

@test "Property: all known secret patterns detected (exhaustive)" {
  local secrets=(
    "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
    "github_pat_11ABCDEF_something"
    "AKIAIOSFODNN7EXAMPLE"
    "sk-abcdefghijklmnopqrstuvwxyz"
    "https://hooks.slack.com/services/T00/B00/xxxx"
  )

  for secret in "${secrets[@]}"; do
    run _is_secret_pattern "$secret"
    [ "$status" -eq 0 ] || {
      echo "FAILED: secret pattern not detected: $secret"
      return 1
    }
  done
}

@test "Property: weak passwords always detected (exhaustive)" {
  local weak=("password" "Password" "PASSWORD" "changeme" "change-me" "secret" "secret123" "admin" "test" "12345" "qwerty" "letmein" "placeholder" "todo" "fixme")

  for pw in "${weak[@]}"; do
    run _is_weak_password "$pw"
    [ "$status" -eq 0 ] || {
      echo "FAILED: weak password not detected: $pw"
      return 1
    }
  done
}

@test "Property: random strong passwords never flagged (100 iterations)" {
  for i in $(seq 1 100); do
    local pw
    pw=$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    # Ensure it doesn't accidentally match a weak pattern
    pw="Str0ng_${pw}"

    run _is_weak_password "$pw"
    [ "$status" -eq 1 ] || {
      echo "FAILED iteration $i: strong password '$pw' flagged as weak"
      return 1
    }
  done
}
