#!/usr/bin/env bats
# ==================================================
# tests/test_init_secrets.bats — Tests for lib/cmd_init_secrets.sh
# ==================================================
# Run:  bats tests/test_init_secrets.bats
# Covers: _secrets_is_placeholder, _secrets_detect_type, _secrets_generate_hex,
#         _secrets_process_template, cmd_init_secrets (dry-run)

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  # Color vars
  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/cmd_init_secrets.sh"
}

teardown() { common_teardown; }

# ── _secrets_is_placeholder ───────────────────────────────────────────────────

@test "_secrets_is_placeholder: empty value is a placeholder" {
  _secrets_is_placeholder ""
}

@test "_secrets_is_placeholder: change-me is a placeholder" {
  _secrets_is_placeholder "change-me"
  _secrets_is_placeholder "change-me-strong-password"
  _secrets_is_placeholder "changeme"
}

@test "_secrets_is_placeholder: your.* is a placeholder" {
  _secrets_is_placeholder "your.vps.ip.address"
  _secrets_is_placeholder "your-domain.com"
}

@test "_secrets_is_placeholder: xxxx patterns are placeholders" {
  _secrets_is_placeholder "xxxx"
  _secrets_is_placeholder "ghp_xxxxxxxxxxxx"
}

@test "_secrets_is_placeholder: actual values are NOT placeholders" {
  ! _secrets_is_placeholder "10.0.0.1"
  ! _secrets_is_placeholder "ubuntu"
  ! _secrets_is_placeholder "my-actual-value"
  ! _secrets_is_placeholder "abc123def456"
  ! _secrets_is_placeholder "postgres"
  ! _secrets_is_placeholder "/home/ubuntu/strut"
}

@test "_secrets_is_placeholder: real passwords are NOT placeholders" {
  ! _secrets_is_placeholder "a1b2c3d4e5f6g7h8"
  ! _secrets_is_placeholder "supersecretvalue123"
}

# ── _secrets_detect_type ──────────────────────────────────────────────────────

@test "_secrets_detect_type: detects hex hint from comment" {
  result=$(_secrets_detect_type "NEXTAUTH_SECRET" "change-me" "# Generate with: openssl rand -hex 32")
  [ "$result" = "hex:32" ]
}

@test "_secrets_detect_type: detects base64 hint from comment" {
  result=$(_secrets_detect_type "ENCRYPTION_KEY" "" "# Generate with: openssl rand -base64 24")
  [ "$result" = "base64:24" ]
}

@test "_secrets_detect_type: auto-detects password type from key name" {
  result=$(_secrets_detect_type "POSTGRES_PASSWORD" "change-me" "")
  [ "$result" = "hex:16" ]
}

@test "_secrets_detect_type: auto-detects secret type from key name" {
  result=$(_secrets_detect_type "JWT_SECRET" "" "")
  [ "$result" = "hex:32" ]

  result=$(_secrets_detect_type "SESSION_SECRET" "change-me" "")
  [ "$result" = "hex:32" ]
}

@test "_secrets_detect_type: auto-detects salt type from key name" {
  result=$(_secrets_detect_type "PASSWORD_SALT" "change-me" "")
  [ "$result" = "hex:16" ]
}

@test "_secrets_detect_type: skips API keys (need external values)" {
  result=$(_secrets_detect_type "OPENAI_API_KEY" "change-me" "")
  [ "$result" = "skip" ]
}

@test "_secrets_detect_type: keeps non-placeholder values" {
  result=$(_secrets_detect_type "POSTGRES_DB" "app_db" "")
  [ "$result" = "keep" ]

  result=$(_secrets_detect_type "PORT" "8000" "")
  [ "$result" = "keep" ]
}

@test "_secrets_detect_type: skips non-secret keys with placeholders" {
  result=$(_secrets_detect_type "DOMAIN" "example.com" "")
  [ "$result" = "skip" ]
}

# ── _secrets_generate_hex ─────────────────────────────────────────────────────

@test "_secrets_generate_hex: generates correct length" {
  result=$(_secrets_generate_hex 16)
  # 16 bytes = 32 hex chars
  [ ${#result} -eq 32 ]
}

@test "_secrets_generate_hex: generates different values each time" {
  result1=$(_secrets_generate_hex 16)
  result2=$(_secrets_generate_hex 16)
  [ "$result1" != "$result2" ]
}

@test "_secrets_generate_hex: output is valid hex" {
  result=$(_secrets_generate_hex 8)
  [[ "$result" =~ ^[0-9a-f]+$ ]]
}

# ── _secrets_process_template ─────────────────────────────────────────────────

@test "_secrets_process_template: generates secrets for password fields" {
  cat > "$TEST_TMP/template" <<'EOF'
POSTGRES_DB=app_db
POSTGRES_PASSWORD=change-me
API_SECRET_KEY=change-me-long-random-secret
PORT=8000
EOF

  local output
  output=$(_secrets_process_template "$TEST_TMP/template" "" "false" 2>/dev/null)

  # POSTGRES_DB and PORT should be unchanged (not placeholders or real values)
  echo "$output" | grep -q "^POSTGRES_DB=app_db$"
  echo "$output" | grep -q "^PORT=8000$"

  # POSTGRES_PASSWORD and API_SECRET_KEY should be generated (not change-me)
  local pw
  pw=$(echo "$output" | grep "^POSTGRES_PASSWORD=" | cut -d= -f2)
  [ -n "$pw" ]
  [ "$pw" != "change-me" ]
  [[ "$pw" =~ ^[0-9a-f]+$ ]]
}

@test "_secrets_process_template: respects generation hints in comments" {
  cat > "$TEST_TMP/template" <<'EOF'
# Generate with: openssl rand -hex 32
NEXTAUTH_SECRET=change-me
EOF

  local output
  output=$(_secrets_process_template "$TEST_TMP/template" "" "false" 2>/dev/null)

  local secret
  secret=$(echo "$output" | grep "^NEXTAUTH_SECRET=" | cut -d= -f2)
  # Should be 64 hex chars (32 bytes)
  [ ${#secret} -eq 64 ]
  [[ "$secret" =~ ^[0-9a-f]+$ ]]
}

@test "_secrets_process_template: preserves existing values" {
  cat > "$TEST_TMP/template" <<'EOF'
POSTGRES_PASSWORD=change-me
JWT_SECRET=change-me
EOF

  cat > "$TEST_TMP/existing" <<'EOF'
POSTGRES_PASSWORD=already-set-value
JWT_SECRET=existing-jwt-secret
EOF

  local output
  output=$(_secrets_process_template "$TEST_TMP/template" "$TEST_TMP/existing" "false" 2>/dev/null)

  echo "$output" | grep -q "^POSTGRES_PASSWORD=already-set-value$"
  echo "$output" | grep -q "^JWT_SECRET=existing-jwt-secret$"
}

@test "_secrets_process_template: force mode overwrites existing values" {
  cat > "$TEST_TMP/template" <<'EOF'
POSTGRES_PASSWORD=change-me
EOF

  cat > "$TEST_TMP/existing" <<'EOF'
POSTGRES_PASSWORD=old-value
EOF

  local output
  output=$(_secrets_process_template "$TEST_TMP/template" "$TEST_TMP/existing" "true" 2>/dev/null)

  local pw
  pw=$(echo "$output" | grep "^POSTGRES_PASSWORD=" | cut -d= -f2)
  [ "$pw" != "old-value" ]
  [ "$pw" != "change-me" ]
}

@test "_secrets_process_template: preserves comments and empty lines" {
  cat > "$TEST_TMP/template" <<'EOF'
# Database config
POSTGRES_DB=mydb

# Secrets
POSTGRES_PASSWORD=change-me
EOF

  local output
  output=$(_secrets_process_template "$TEST_TMP/template" "" "false" 2>/dev/null)

  echo "$output" | grep -q "^# Database config$"
  echo "$output" | grep -q "^# Secrets$"
  echo "$output" | grep -q "^POSTGRES_DB=mydb$"
}

@test "_secrets_process_template: outputs generation counts to stderr" {
  cat > "$TEST_TMP/template" <<'EOF'
POSTGRES_DB=mydb
POSTGRES_PASSWORD=change-me
JWT_SECRET=change-me
PORT=8000
EOF

  local counts
  counts=$(_secrets_process_template "$TEST_TMP/template" "" "false" 2>&1 >/dev/null)

  echo "$counts" | grep -q "GENERATED=2"
  echo "$counts" | grep -q "SKIPPED=2"  # POSTGRES_DB=keep, PORT=keep → counted as skipped
}

# ── cmd_init_secrets ──────────────────────────────────────────────────────────

@test "cmd_init_secrets: dry-run prints generated env without writing" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/.env.template" <<'EOF'
POSTGRES_DB=app_db
POSTGRES_PASSWORD=change-me
PORT=3000
EOF

  export CMD_STACK="$stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/$stack"
  export CMD_ENV_NAME="prod"
  export DRY_RUN=true

  run cmd_init_secrets
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"POSTGRES_DB=app_db"* ]]
  [[ "$output" == *"PORT=3000"* ]]
  # Should have generated a secret for POSTGRES_PASSWORD
  [[ "$output" != *"POSTGRES_PASSWORD=change-me"* ]]
  # File should NOT exist
  [ ! -f "$TEST_TMP/.prod.env" ]
}

@test "cmd_init_secrets: writes env file in normal mode" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/.env.template" <<'EOF'
POSTGRES_PASSWORD=change-me
PORT=3000
EOF

  export CMD_STACK="$stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/$stack"
  export CMD_ENV_NAME="prod"
  export DRY_RUN=false

  run cmd_init_secrets
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.prod.env" ]

  # Verify contents
  local pw
  pw=$(grep "^POSTGRES_PASSWORD=" "$TEST_TMP/.prod.env" | cut -d= -f2)
  [ -n "$pw" ]
  [ "$pw" != "change-me" ]
  grep -q "^PORT=3000$" "$TEST_TMP/.prod.env"
}

@test "cmd_init_secrets: fails when no template exists" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  export CMD_STACK="$stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/$stack"
  export CMD_ENV_NAME="prod"
  export DRY_RUN=false

  # Use exit-based fail in run subshell
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_init_secrets
  [ "$status" -ne 0 ]
  [[ "$output" == *".env.template"* ]]
}

@test "cmd_init_secrets: uses --env name for output file" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/.env.template" <<'EOF'
APP_SECRET=change-me
EOF

  export CMD_STACK="$stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/$stack"
  export CMD_ENV_NAME="staging"
  export DRY_RUN=false

  run cmd_init_secrets
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.staging.env" ]
}

@test "_usage_init_secrets: prints usage information" {
  run _usage_init_secrets
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--env"* ]]
  [[ "$output" == *"--force"* ]]
  [[ "$output" == *"--dry-run"* ]]
}
