#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_template.bats — Tests for `secrets template`
# ==================================================
# Run:  bats tests/test_secrets_template.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail()         { echo "FAIL: $1" >&2; return 1; }
  ok()           { echo "OK: $*"; }
  warn()         { echo "WARN: $*" >&2; }
  log()          { echo "LOG: $*"; }
  error()        { echo "ERROR: $*" >&2; }
  print_banner() { echo "== $* =="; }
  export -f fail ok warn log error print_banner

  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/topology.sh"
  source "$CLI_ROOT/lib/secrets_providers.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"

  export HOME="$TEST_TMP/fakehome"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  export _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()
}

teardown() { common_teardown; }

# ── basic output ──────────────────────────────────────────────────────────────

@test "secrets template: creates .env.template from .env" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASSWORD=abc12345678901234567890abcdef12\nAPP_NAME=myapp\n' \
    > "$CMD_STACK_DIR/.prod.env"

  _secrets_template
  [ -f "$CMD_STACK_DIR/.env.template" ]
}

@test "secrets template: replaces long hex secret with change-me" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  # 64-char hex = 32-byte secret
  printf 'DB_PASSWORD=aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899\n' \
    > "$CMD_STACK_DIR/.prod.env"

  _secrets_template
  grep -q 'change-me' "$CMD_STACK_DIR/.env.template"
  ! grep -q 'aabbccdd' "$CMD_STACK_DIR/.env.template"
}

@test "secrets template: keeps URL literals unchanged" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DATABASE_URL=postgresql://localhost:5432/mydb\nSECRET=aabbccddeeff00112233445566778899\n' \
    > "$CMD_STACK_DIR/.prod.env"

  _secrets_template
  grep -q 'DATABASE_URL=postgresql://localhost:5432/mydb' "$CMD_STACK_DIR/.env.template"
}

@test "secrets template: keeps integer port / boolean literals" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'PORT=3000\nDEBUG=false\n' > "$CMD_STACK_DIR/.prod.env"

  _secrets_template
  grep -q 'PORT=3000' "$CMD_STACK_DIR/.env.template"
  grep -q 'DEBUG=false' "$CMD_STACK_DIR/.env.template"
}

@test "secrets template: adds generation hint for hex secret" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'JWT_SECRET=aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899\n' \
    > "$CMD_STACK_DIR/.prod.env"

  _secrets_template
  grep -q 'openssl rand' "$CMD_STACK_DIR/.env.template"
}

@test "secrets template: dry-run does not write file" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASSWORD=secret123456789012345678901234\n' > "$CMD_STACK_DIR/.prod.env"

  _secrets_template --dry-run
  [ ! -f "$CMD_STACK_DIR/.env.template" ]
}

@test "secrets template: dry-run prints template contents" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASSWORD=aabbccddeeff00112233445566778899\n' > "$CMD_STACK_DIR/.prod.env"

  output=$(_secrets_template --dry-run 2>&1)
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"change-me"* ]]
}

@test "secrets template: aborts when template exists without --force" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASSWORD=abc123\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'EXISTING=template\n' > "$CMD_STACK_DIR/.env.template"

  run _secrets_template 2>&1
  [ "$status" -ne 0 ]
  grep -q 'EXISTING=template' "$CMD_STACK_DIR/.env.template"
}

@test "secrets template: --force overwrites existing template" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASSWORD=aabbccddeeff00112233445566778899\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'OLD=content\n' > "$CMD_STACK_DIR/.env.template"

  _secrets_template --force
  ! grep -q 'OLD=content' "$CMD_STACK_DIR/.env.template"
}

@test "secrets template: fails when no local env file" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"

  run _secrets_template 2>&1
  [ "$status" -ne 0 ]
}

@test "secrets template: dispatches via cmd_secrets" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASSWORD=aabbccddeeff00112233445566778899\n' > "$CMD_STACK_DIR/.prod.env"

  run cmd_secrets template --dry-run 2>&1
  [[ "$output" == *"Secrets Template"* ]]
}
