#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_validate.bats — Tests for enhanced `secrets validate`
# ==================================================
# Run:  bats tests/test_secrets_validate.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail()        { echo "FAIL: $1" >&2; return 1; }
  ok()          { echo "OK: $*"; }
  warn()        { echo "WARN: $*"; }
  log()         { echo "LOG: $*"; }
  error()       { echo "ERROR: $*" >&2; }
  print_banner(){ echo "== $* =="; }
  export -f fail ok warn log error print_banner

  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/secrets_providers.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"

  export CMD_STACK="test-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
}

teardown() { common_teardown; }

# ── _secrets_check_content ────────────────────────────────────────────────────

@test "check_content: passes clean env file" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=a8f3b2e91cd04
API_TOKEN=realtoken123xyz
FEATURE_FLAG=true
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 0 ]
}

@test "check_content: detects changeme placeholder" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
DB_PASSWORD=changeme
VPS_HOST=1.2.3.4
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DB_PASSWORD"* ]]
  [[ "$output" == *"placeholder"* ]]
}

@test "check_content: detects quoted placeholder (DB_PASSWORD=\"changeme\")" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
DB_PASSWORD="changeme"
VPS_HOST=1.2.3.4
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DB_PASSWORD"* ]]
  [[ "$output" == *"placeholder"* ]]
}

@test "check_content: detects xxxx placeholder" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
API_KEY=xxxx
VPS_HOST=1.2.3.4
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"API_KEY"* ]]
  [[ "$output" == *"placeholder"* ]]
}

@test "check_content: detects your-* placeholder" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
SECRET_KEY=your-secret-here
VPS_HOST=1.2.3.4
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SECRET_KEY"* ]]
}

@test "check_content: detects todo placeholder" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
API_SECRET=TODO
VPS_HOST=1.2.3.4
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"API_SECRET"* ]]
}

@test "check_content: detects weak password in PASSWORD key" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=password
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DB_PASSWORD"* ]]
  [[ "$output" == *"weak"* ]]
}

@test "check_content: detects weak password in SECRET key" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
APP_SECRET=secret
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"APP_SECRET"* ]]
}

@test "check_content: detects unresolved vault:// reference" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=vault://myapp.db-password
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DB_PASSWORD"* ]]
  [[ "$output" == *"unresolved"* ]]
}

@test "check_content: detects unresolved exec:// reference" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
API_TOKEN=exec://get-token.sh
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"API_TOKEN"* ]]
  [[ "$output" == *"unresolved"* ]]
}

@test "check_content: detects unresolved file:// reference" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=file:///run/secrets/db-password
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DB_PASSWORD"* ]]
  [[ "$output" == *"unresolved"* ]]
}

@test "check_content: reports multiple issues at once" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
DB_PASSWORD=changeme
API_TOKEN=vault://myapp.token
SECRET_KEY=placeholder
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DB_PASSWORD"* ]]
  [[ "$output" == *"API_TOKEN"* ]]
  [[ "$output" == *"SECRET_KEY"* ]]
}

@test "check_content: skips comment lines" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
# This is a comment with vault://something
VPS_HOST=1.2.3.4
DB_PASSWORD=a8f3b2e91cd04
EOF
  run _secrets_check_content "$TEST_TMP/.prod.env"
  [ "$status" -eq 0 ]
}

# ── _secrets_validate ─────────────────────────────────────────────────────────

@test "validate: passes clean env with required_vars satisfied" {
  cat > "$CMD_STACK_DIR/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=strongpassword99
API_TOKEN=realtoken123xyz
EOF
  printf 'VPS_HOST\nDB_PASSWORD\n' > "$CMD_STACK_DIR/required_vars"

  run _secrets_validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validation passed"* ]]
}

@test "validate: fails when required var is missing" {
  cat > "$CMD_STACK_DIR/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
EOF
  printf 'VPS_HOST\nDB_PASSWORD\n' > "$CMD_STACK_DIR/required_vars"

  run _secrets_validate 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"DB_PASSWORD"* ]]
}

@test "validate: fails when placeholder value present" {
  cat > "$CMD_STACK_DIR/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=changeme
EOF

  run _secrets_validate 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"DB_PASSWORD"* ]]
}

@test "validate: fails when unresolved vault reference present" {
  cat > "$CMD_STACK_DIR/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=vault://myapp.db
EOF

  run _secrets_validate 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"unresolved"* ]]
}

@test "validate: passes when no required_vars file exists" {
  cat > "$CMD_STACK_DIR/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=strongpassword99
EOF
  # No required_vars file

  run _secrets_validate 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validation passed"* ]]
}

@test "validate: reports both missing vars and content issues" {
  cat > "$CMD_STACK_DIR/.prod.env" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=changeme
EOF
  printf 'VPS_HOST\nDB_PASSWORD\nMISSING_VAR\n' > "$CMD_STACK_DIR/required_vars"

  run _secrets_validate 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING_VAR"* ]]
  [[ "$output" == *"DB_PASSWORD"* ]]
}

# ── _secrets_hydrate post-hydration warning ───────────────────────────────────

@test "hydrate: warns when required_vars entry missing from output" {
  mkdir -p "$CMD_STACK_DIR"
  cat > "$CMD_STACK_DIR/.prod.env.template" <<'EOF'
VPS_HOST=1.2.3.4
LITERAL_VAL=present
EOF
  printf 'VPS_HOST\nLITERAL_VAL\nMISSING_IN_TEMPLATE\n' > "$CMD_STACK_DIR/required_vars"

  export DRY_RUN=false

  run _secrets_hydrate --force 2>&1
  # hydrate itself succeeds (template is valid)
  [ "$status" -eq 0 ]
  # but warns about the missing required var
  [[ "$output" == *"MISSING_IN_TEMPLATE"* ]]
  [[ "$output" == *"required var"* ]]
}

@test "hydrate: no warning when all required_vars are present in output" {
  mkdir -p "$CMD_STACK_DIR"
  cat > "$CMD_STACK_DIR/.prod.env.template" <<'EOF'
VPS_HOST=1.2.3.4
DB_PASSWORD=strongpass99
EOF
  printf 'VPS_HOST\nDB_PASSWORD\n' > "$CMD_STACK_DIR/required_vars"

  export DRY_RUN=false

  run _secrets_hydrate --force 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" != *"required var"* ]]
}
