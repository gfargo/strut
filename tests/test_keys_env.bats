#!/usr/bin/env bats
# ==================================================
# tests/test_keys_env.bats — Tests for lib/keys/env.sh env-aware wrappers
# ==================================================
# Run:  bats tests/test_keys_env.bats
# Covers: keys_env_set/rotate/sync/validate/backup/diff respecting the
# passed-in env_file (not hardcoding .prod.env), atomic writes, masking.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/keys.sh"

  confirm() { return 0; }
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-keysenv-"*
  rm -rf "$TEST_TMP"
}

# ── keys_env_set: respects passed-in env_file, not $CLI_ROOT/.prod.env ──────

@test "keys_env_set: writes to the passed-in staging env file, not .prod.env" {
  local stack="test-keysenv-set-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'EXISTING=1\n' > "$env_file"

  run keys_env_set "$stack" "$env_file" MY_KEY myvalue
  [ "$status" -eq 0 ]
  grep -q "^MY_KEY=myvalue$" "$env_file"
  # .prod.env at CLI_ROOT must be untouched
  [ ! -f "$CLI_ROOT/.prod.env" ]
}

@test "keys_env_set: staging file ends up mode 600" {
  local stack="test-keysenv-perm-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'EXISTING=1\n' > "$env_file"
  chmod 644 "$env_file"

  run keys_env_set "$stack" "$env_file" MY_KEY myvalue
  [ "$status" -eq 0 ]
  perms=$(stat -c "%a" "$env_file" 2>/dev/null || stat -f "%OLp" "$env_file")
  [ "$perms" = "600" ]
}

@test "keys_env_set: updates an existing key in place" {
  local stack="test-keysenv-update-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'MY_KEY=old\nOTHER=1\n' > "$env_file"

  run keys_env_set "$stack" "$env_file" MY_KEY newval
  [ "$status" -eq 0 ]
  grep -q "^MY_KEY=newval$" "$env_file"
  grep -q "^OTHER=1$" "$env_file"
}

@test "keys_env_set: rejects invalid key format" {
  local stack="test-keysenv-badkey-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'EXISTING=1\n' > "$env_file"

  run keys_env_set "$stack" "$env_file" not_valid myvalue
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Invalid key format" ]]
}

@test "keys_env_set: leaves no .tmp litter behind" {
  local stack="test-keysenv-litter-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'EXISTING=1\n' > "$env_file"

  run keys_env_set "$stack" "$env_file" MY_KEY myvalue
  [ "$status" -eq 0 ]
  # No .tmp file left behind by the old sed -i.tmp approach
  [ ! -f "$env_file.tmp" ]
}

@test "keys_env_set: dry-run performs no mutation" {
  local stack="test-keysenv-dry-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'EXISTING=1\n' > "$env_file"

  run keys_env_set "$stack" "$env_file" MY_KEY myvalue --dry-run
  [ "$status" -eq 0 ]
  ! grep -q "MY_KEY" "$env_file"
}

# ── keys_env_validate / keys_env_sync: respect passed-in env_file ──────────

@test "keys_env_validate: validates the passed-in staging file against the stack template" {
  local stack="test-keysenv-validate-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  printf 'FOO=x\nBAR=y\n' > "$CLI_ROOT/stacks/$stack/.env.template"
  local env_file="$TEST_TMP/.staging.env"
  printf 'FOO=1\n' > "$env_file"

  run keys_env_validate "$stack" "$env_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BAR"* ]]
}

@test "keys_env_sync: adds missing keys to the passed-in staging file" {
  local stack="test-keysenv-sync-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  printf 'FOO=x\nBAR=y\n' > "$CLI_ROOT/stacks/$stack/.env.template"
  local env_file="$TEST_TMP/.staging.env"
  printf 'FOO=1\n' > "$env_file"

  run keys_env_sync "$stack" "$env_file"
  [ "$status" -eq 0 ]
  grep -q "^BAR=y$" "$env_file"
  [ ! -f "$CLI_ROOT/.prod.env" ]
}

# ── keys_env_backup: respects passed-in env_file, chmod 600 ────────────────

@test "keys_env_backup: backs up the passed-in staging file with mode 600" {
  local stack="test-keysenv-backup-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'FOO=1\n' > "$env_file"

  run keys_env_backup "$stack" "$env_file"
  [ "$status" -eq 0 ]
  local backup_file
  backup_file=$(find "$CLI_ROOT/stacks/$stack/keys" -maxdepth 1 -name 'env-backup-*' | head -1)
  [ -n "$backup_file" ]
  perms=$(stat -c "%a" "$backup_file" 2>/dev/null || stat -f "%OLp" "$backup_file")
  [ "$perms" = "600" ]
}

# ── keys_env_diff: masked comparison, never leaks values ────────────────────

@test "keys_env_diff: output contains only key markers, never a seeded secret value" {
  local stack="test-keysenv-diff-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'VPS_HOST=127.0.0.1\nVPS_USER=deploy\n' > "$env_file"
  local local_file="$TEST_TMP/local-compare.env"
  printf 'DB_PASSWORD=localsupersecret\nSHARED=1\n' > "$local_file"

  resolve_deploy_dir() { echo "/opt/app"; }
  build_ssh_opts() { echo ""; }
  scp() {
    # Simulate the remote fetch: write a fixture to the destination temp file
    local dest="${@: -1}"
    printf 'DB_PASSWORD=remotesupersecret\nSHARED=1\n' > "$dest"
  }

  run keys_env_diff "$stack" "$env_file" --local "$local_file" --remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"~ DB_PASSWORD"* ]]
  [[ "$output" != *"localsupersecret"* ]]
  [[ "$output" != *"remotesupersecret"* ]]
}

@test "keys_env_diff: fetches the remote file to a private temp path, not a predictable /tmp/remote-env-\$\$" {
  local stack="test-keysenv-difftmp-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'VPS_HOST=127.0.0.1\n' > "$env_file"
  local local_file="$TEST_TMP/local-compare.env"
  printf 'FOO=1\n' > "$local_file"

  resolve_deploy_dir() { echo "/opt/app"; }
  build_ssh_opts() { echo ""; }
  scp() {
    local dest="${@: -1}"
    [[ "$dest" != "/tmp/remote-env-"* ]] || { echo "used predictable tmp path" >&2; return 1; }
    printf 'FOO=1\n' > "$dest"
  }

  run keys_env_diff "$stack" "$env_file" --local "$local_file" --remote
  [ "$status" -eq 0 ]
  [[ "$output" != *"used predictable tmp path"* ]]
}

@test "keys_env_diff: cleans up the remote temp file after comparison" {
  local stack="test-keysenv-diffcleanup-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/.staging.env"
  printf 'VPS_HOST=127.0.0.1\n' > "$env_file"
  local local_file="$TEST_TMP/local-compare.env"
  printf 'FOO=1\n' > "$local_file"

  local captured_dest=""
  resolve_deploy_dir() { echo "/opt/app"; }
  build_ssh_opts() { echo ""; }
  scp() {
    captured_dest="${@: -1}"
    printf 'FOO=1\n' > "$captured_dest"
  }

  run keys_env_diff "$stack" "$env_file" --local "$local_file" --remote
  [ "$status" -eq 0 ]
  [ ! -f "$captured_dest" ]
}
