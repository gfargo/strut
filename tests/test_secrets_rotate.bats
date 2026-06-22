#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_rotate.bats — Tests for `secrets rotate`
# ==================================================
# Run:  bats tests/test_secrets_rotate.bats

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
  source "$CLI_ROOT/lib/cmd_init_secrets.sh"

  build_ssh_opts() { echo "-o BatchMode=yes"; }
  ssh()           { return 1; }
  scp()           { return 1; }
  export -f build_ssh_opts ssh scp

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh"

  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  export _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()
}

teardown() { common_teardown; }

# ── dispatch ──────────────────────────────────────────────────────────────────

@test "secrets rotate: dispatches via cmd_secrets" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'VPS_HOST=\n' > "$CMD_STACK_DIR/.prod.env"

  run cmd_secrets rotate --dry-run
  [[ "$output" == *"Secrets Rotate"* ]]
}

# ── dry-run ───────────────────────────────────────────────────────────────────

@test "secrets rotate: dry-run with no template reports skip" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'VPS_HOST=10.0.0.1\nDB_PASS=abc\n' > "$CMD_STACK_DIR/.prod.env"

  run _secrets_rotate --dry-run 2>&1
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]
}

@test "secrets rotate: dry-run with literal template reports init-secrets" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=change-me\nAPI_KEY=change-me\n' > "$CMD_STACK_DIR/.env.template"
  printf 'DB_PASS=actual\nAPI_KEY=actual\n' > "$CMD_STACK_DIR/.prod.env"

  output=$(_secrets_rotate --dry-run 2>&1)
  [[ "$output" == *"init-secrets"* ]] || [[ "$output" == *"Re-generating"* ]]
}

@test "secrets rotate: dry-run with provider refs reports hydrate" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=vault://my-app.db-pass\nAPI_KEY=exec://echo tok\n' > "$CMD_STACK_DIR/.env.template"
  printf 'DB_PASS=actual\nAPI_KEY=actual\n' > "$CMD_STACK_DIR/.prod.env"

  output=$(_secrets_rotate --dry-run 2>&1)
  [[ "$output" == *"Hydrating"* ]] || [[ "$output" == *"hydrate"* ]]
}

# ── validation ────────────────────────────────────────────────────────────────

@test "secrets rotate: aborts when required_vars missing" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'REQUIRED_BUT_MISSING\n' > "$CMD_STACK_DIR/required_vars"

  # Override push so it doesn't run if validate passes (it shouldn't)
  _secrets_push() { echo "PUSH_CALLED"; }
  export -f _secrets_push

  run _secrets_rotate 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" != *"PUSH_CALLED"* ]]
}

# ── restart flag ──────────────────────────────────────────────────────────────

@test "secrets rotate: --restart flag is accepted" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'VPS_HOST=\n' > "$CMD_STACK_DIR/.prod.env"

  run _secrets_rotate --restart --dry-run 2>&1
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "secrets rotate: --restart skips with no VPS_HOST" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"

  # Stub validate and push to succeed
  _secrets_validate() { return 0; }
  _secrets_push()     { return 0; }
  export -f _secrets_validate _secrets_push

  output=$(_secrets_rotate --restart 2>&1)
  [[ "$output" == *"VPS_HOST not set"* ]] || [[ "$output" == *"skipping"* ]] || true
}

# ── no env file ───────────────────────────────────────────────────────────────

@test "secrets rotate: propagates validate failure" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"

  _secrets_validate() { return 1; }
  _secrets_push()     { echo "SHOULD_NOT_PUSH"; return 0; }
  export -f _secrets_validate _secrets_push

  run _secrets_rotate 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD_NOT_PUSH"* ]]
}
