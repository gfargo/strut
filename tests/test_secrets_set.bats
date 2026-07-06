#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_set.bats — Tests for `secrets set` and `_secrets_write_var`
# ==================================================
# Run:  bats tests/test_secrets_set.bats

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

# ── _secrets_write_var ────────────────────────────────────────────────────────

@test "_secrets_write_var: appends a new key" {
  printf 'FOO=1\n' > "$TEST_TMP/.env"
  run _secrets_write_var "$TEST_TMP/.env" "NEW_KEY" "newval"
  [ "$status" -eq 0 ]
  grep -q "^NEW_KEY=newval$" "$TEST_TMP/.env"
  grep -q "^FOO=1$" "$TEST_TMP/.env"
}

@test "_secrets_write_var: updates an existing key in place" {
  printf 'FOO=1\nDB_PASS=old\nBAR=2\n' > "$TEST_TMP/.env"
  run _secrets_write_var "$TEST_TMP/.env" "DB_PASS" "newvalue"
  [ "$status" -eq 0 ]
  local content
  content=$(cat "$TEST_TMP/.env")
  [[ "$content" == $'FOO=1\nDB_PASS=newvalue\nBAR=2' ]]
}

@test "_secrets_write_var: rejects invalid key format" {
  printf 'FOO=1\n' > "$TEST_TMP/.env"
  run _secrets_write_var "$TEST_TMP/.env" "not-a-valid-key" "val"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Invalid key format" ]]
  # File must be untouched on rejection
  grep -q "^FOO=1$" "$TEST_TMP/.env"
  ! grep -q "not-a-valid-key" "$TEST_TMP/.env"
}

@test "_secrets_write_var: leaves no .tmp or stray files behind" {
  printf 'FOO=1\n' > "$TEST_TMP/.env"
  run _secrets_write_var "$TEST_TMP/.env" "FOO" "2"
  [ "$status" -eq 0 ]
  local stray
  stray=$(find "$TEST_TMP" -maxdepth 1 -name '.*' -not -name '.env' -not -name '.' -not -name '..')
  [ -z "$stray" ]
}

@test "_secrets_write_var: result file is mode 600" {
  printf 'FOO=1\n' > "$TEST_TMP/.env"
  chmod 644 "$TEST_TMP/.env"
  run _secrets_write_var "$TEST_TMP/.env" "FOO" "2"
  [ "$status" -eq 0 ]
  perms=$(stat -c "%a" "$TEST_TMP/.env" 2>/dev/null || stat -f "%OLp" "$TEST_TMP/.env")
  [ "$perms" = "600" ]
}

@test "_secrets_write_var: creates the file when it doesn't exist yet" {
  run _secrets_write_var "$TEST_TMP/.new.env" "FOO" "bar"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/.new.env" ]
  grep -q "^FOO=bar$" "$TEST_TMP/.new.env"
}

# ── _secrets_set (dispatcher-level) ──────────────────────────────────────────

@test "secrets set: sets value via --value" {
  printf 'EXISTING=1\n' > "$CMD_STACK_DIR/.prod.env"
  run _secrets_set MY_KEY --value supersecret
  [ "$status" -eq 0 ]
  [[ "$output" == *"Set MY_KEY (added)"* ]]
  grep -q "^MY_KEY=supersecret$" "$CMD_STACK_DIR/.prod.env"
}

@test "secrets set: sets value via stdin when --value omitted" {
  printf 'EXISTING=1\n' > "$CMD_STACK_DIR/.prod.env"
  run _secrets_set STDIN_KEY <<< "fromstdin"
  [ "$status" -eq 0 ]
  grep -q "^STDIN_KEY=fromstdin$" "$CMD_STACK_DIR/.prod.env"
}

@test "secrets set: never echoes the value in output" {
  printf 'EXISTING=1\n' > "$CMD_STACK_DIR/.prod.env"
  run _secrets_set SUPER_SECRET --value "topsecretvalue12345"
  [ "$status" -eq 0 ]
  [[ "$output" != *"topsecretvalue12345"* ]]
}

@test "secrets set: reports 'updated' for an existing key" {
  printf 'MY_KEY=oldvalue\n' > "$CMD_STACK_DIR/.prod.env"
  run _secrets_set MY_KEY --value newvalue
  [ "$status" -eq 0 ]
  [[ "$output" == *"Set MY_KEY (updated)"* ]]
  grep -q "^MY_KEY=newvalue$" "$CMD_STACK_DIR/.prod.env"
}

@test "secrets set: fails without a key" {
  printf 'EXISTING=1\n' > "$CMD_STACK_DIR/.prod.env"
  run _secrets_set --value abc
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage" ]]
}

@test "secrets set: fails when no local env file is found" {
  run _secrets_set MY_KEY --value abc
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No local env file" ]]
}

@test "secrets set: result file is mode 600" {
  printf 'EXISTING=1\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 644 "$CMD_STACK_DIR/.prod.env"
  run _secrets_set MY_KEY --value abc
  [ "$status" -eq 0 ]
  perms=$(stat -c "%a" "$CMD_STACK_DIR/.prod.env" 2>/dev/null || stat -f "%OLp" "$CMD_STACK_DIR/.prod.env")
  [ "$perms" = "600" ]
}

@test "secrets set: dispatches via cmd_secrets" {
  printf 'EXISTING=1\n' > "$CMD_STACK_DIR/.prod.env"
  run cmd_secrets set MY_KEY --value viaDispatch
  [ "$status" -eq 0 ]
  grep -q "^MY_KEY=viaDispatch$" "$CMD_STACK_DIR/.prod.env"
}

# ── _secrets_render_env_diff ──────────────────────────────────────────────────

@test "_secrets_render_env_diff: never prints a value" {
  printf 'FOO=localsecretvalue\nBAR=1\n' > "$TEST_TMP/local.env"
  printf 'FOO=remotesecretvalue\nBAR=1\n' > "$TEST_TMP/remote.env"
  run _secrets_render_env_diff "$TEST_TMP/local.env" "$TEST_TMP/remote.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"~ FOO"* ]]
  [[ "$output" != *"localsecretvalue"* ]]
  [[ "$output" != *"remotesecretvalue"* ]]
}

@test "_secrets_render_env_diff: shows only-in-local and only-in-remote keys" {
  printf 'FOO=1\nONLY_LOCAL=x\n' > "$TEST_TMP/local.env"
  printf 'FOO=1\nONLY_REMOTE=y\n' > "$TEST_TMP/remote.env"
  run _secrets_render_env_diff "$TEST_TMP/local.env" "$TEST_TMP/remote.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ ONLY_LOCAL"* ]]
  [[ "$output" == *"- ONLY_REMOTE"* ]]
}

@test "_secrets_render_env_diff: reports in sync when identical" {
  printf 'FOO=1\nBAR=2\n' > "$TEST_TMP/local.env"
  printf 'FOO=1\nBAR=2\n' > "$TEST_TMP/remote.env"
  run _secrets_render_env_diff "$TEST_TMP/local.env" "$TEST_TMP/remote.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
}
