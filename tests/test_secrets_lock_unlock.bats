#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_lock_unlock.bats — Tests for `secrets lock` and `secrets unlock`
# ==================================================
# Run:  bats tests/test_secrets_lock_unlock.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail()        { echo "FAIL: $1" >&2; return 1; }
  ok()          { echo "OK: $*"; }
  warn()        { echo "WARN: $*" >&2; }
  log()         { echo "LOG: $*"; }
  error()       { echo "ERROR: $*" >&2; }
  print_banner(){ echo "== $* =="; }
  export -f fail ok warn log error print_banner

  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/secrets_providers.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"

  # Fake age: copies input→output for both -e and -d, ignores other flags
  age() {
    local output="" input=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -e|-d)        shift ;;
        -o)           output="$2"; shift 2 ;;
        -R)           shift 2 ;;
        -i)           shift 2 ;;
        *)            input="$1"; shift ;;
      esac
    done
    [ -n "$output" ] && [ -n "$input" ] && cp "$input" "$output"
  }
  export -f age

  # Fake gpg: copies input→output for both --symmetric and --decrypt
  gpg() {
    local output="" input=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --symmetric|--decrypt|--armor|--batch|--yes) shift ;;
        --output)     output="$2"; shift 2 ;;
        *)            input="$1"; shift ;;
      esac
    done
    [ -n "$output" ] && [ -n "$input" ] && cp "$input" "$output"
  }
  export -f gpg

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh" "$HOME/.age"
}

teardown() { common_teardown; }

# ── _secrets_detect_backend ─────────────────────────────────────────────────

@test "_secrets_detect_backend: returns age when age mock is available" {
  run _secrets_detect_backend
  [ "$status" -eq 0 ]
  [ "$output" = "age" ]
}

@test "_secrets_detect_backend: returns gpg when age unavailable but gpg present" {
  # Unset age mock so command -v age fails
  unset -f age
  run _secrets_detect_backend
  [ "$status" -eq 0 ]
  [ "$output" = "gpg" ]
}

@test "_secrets_detect_backend: fails when neither backend available" {
  unset -f age
  unset -f gpg
  # PATH must be restricted so real gpg/age binaries (present on many CI systems) are not found
  local empty_bin="$TEST_TMP/empty-bin"
  mkdir -p "$empty_bin"
  local saved_PATH="$PATH"
  PATH="$empty_bin"
  run _secrets_detect_backend
  PATH="$saved_PATH"
  [ "$status" -ne 0 ]
}

# ── _secrets_lock ────────────────────────────────────────────────────────────

@test "secrets lock: fails when no env file found" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"

  run _secrets_lock --backend age
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No local env file" ]]
}

@test "secrets lock: fails when no encryption backend available" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'age1testkey\n' > "$CLI_ROOT/.strut-recipients"

  unset -f age
  unset -f gpg
  # PATH must be restricted so real gpg/age binaries (present on many CI systems) are not found
  local empty_bin="$TEST_TMP/empty-bin"
  mkdir -p "$empty_bin"
  local saved_PATH="$PATH"
  PATH="$empty_bin"
  run _secrets_lock
  PATH="$saved_PATH"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No encryption backend" ]]
}

@test "secrets lock: encrypts with age using stack-level .strut-recipients" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\nAPI_KEY=abc\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'age1testkey\n' > "$CMD_STACK_DIR/.strut-recipients"

  run _secrets_lock --backend age
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]
}

@test "secrets lock: encrypts with age using project-level .strut-recipients" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'age1testkey\n' > "$CLI_ROOT/.strut-recipients"

  run _secrets_lock --backend age
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]
}

@test "secrets lock: encrypts with age using SSH pubkey as self-recipient when no .strut-recipients" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'ssh-ed25519 AAAA fakepubkey user@host\n' > "$HOME/.ssh/id_ed25519.pub"

  run _secrets_lock --backend age
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]
}

@test "secrets lock: removes plaintext by default" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'age1testkey\n' > "$CLI_ROOT/.strut-recipients"

  run _secrets_lock --backend age
  [ "$status" -eq 0 ]
  [ ! -f "$CMD_STACK_DIR/.prod.env" ]
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]
}

@test "secrets lock: keeps plaintext with --keep" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'age1testkey\n' > "$CLI_ROOT/.strut-recipients"

  run _secrets_lock --backend age --keep
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env" ]
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]
}

@test "secrets lock: dry-run shows plan without making changes" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export DRY_RUN="true"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'age1testkey\n' > "$CLI_ROOT/.strut-recipients"

  run _secrets_lock --backend age
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DRY-RUN" ]]
  [ ! -f "$CMD_STACK_DIR/.prod.env.age" ]
  [ -f "$CMD_STACK_DIR/.prod.env" ]

  export DRY_RUN="false"
}

@test "secrets lock: warns if encrypted file already exists without --force" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'old-encrypted\n' > "$CMD_STACK_DIR/.prod.env.age"
  printf 'age1testkey\n' > "$CLI_ROOT/.strut-recipients"

  run _secrets_lock --backend age
  [ "$status" -ne 0 ]
  [[ "$output" =~ "already exists" ]]
  # Plaintext must still be present (not removed on failure)
  [ -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "secrets lock: overwrites encrypted file with --force" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=newvalue\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'old-encrypted\n' > "$CMD_STACK_DIR/.prod.env.age"
  printf 'age1testkey\n' > "$CLI_ROOT/.strut-recipients"

  run _secrets_lock --backend age --force
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]
  result=$(cat "$CMD_STACK_DIR/.prod.env.age")
  [[ "$result" == *"DB_PASS=newvalue"* ]]
}

@test "secrets lock: encrypts with gpg backend" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env"

  run _secrets_lock --backend gpg
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env.gpg" ]
}

# ── _secrets_unlock ──────────────────────────────────────────────────────────

@test "secrets unlock: fails when no encrypted file found" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"

  run _secrets_unlock
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No encrypted env file" ]]
}

@test "secrets unlock: decrypts age file to .env with mode 600" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env.age"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$HOME/.age/key.txt"

  run _secrets_unlock
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env" ]
  perms=$(stat -c "%a" "$CMD_STACK_DIR/.prod.env" 2>/dev/null || stat -f "%OLp" "$CMD_STACK_DIR/.prod.env")
  [ "$perms" = "600" ]
}

@test "secrets unlock: removes encrypted file by default" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env.age"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$HOME/.age/key.txt"

  run _secrets_unlock
  [ "$status" -eq 0 ]
  [ ! -f "$CMD_STACK_DIR/.prod.env.age" ]
  [ -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "secrets unlock: keeps encrypted file with --keep" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env.age"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$HOME/.age/key.txt"

  run _secrets_unlock --keep
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]
  [ -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "secrets unlock: warns if plaintext already exists without --force" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env.age"
  printf 'DB_PASS=old\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$HOME/.age/key.txt"

  run _secrets_unlock
  [ "$status" -ne 0 ]
  [[ "$output" =~ "already exists" ]]
  # Encrypted file must be preserved on failure
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]
}

@test "secrets unlock: overwrites plaintext with --force" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=newvalue\n' > "$CMD_STACK_DIR/.prod.env.age"
  printf 'DB_PASS=old\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$HOME/.age/key.txt"

  run _secrets_unlock --force
  [ "$status" -eq 0 ]
  result=$(cat "$CMD_STACK_DIR/.prod.env")
  [[ "$result" == *"DB_PASS=newvalue"* ]]
}

@test "secrets unlock: dry-run shows plan without making changes" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export DRY_RUN="true"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env.age"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$HOME/.age/key.txt"

  run _secrets_unlock
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DRY-RUN" ]]
  [ ! -f "$CMD_STACK_DIR/.prod.env" ]
  [ -f "$CMD_STACK_DIR/.prod.env.age" ]

  export DRY_RUN="false"
}

@test "secrets unlock: uses --identity flag for age decryption" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env.age"
  local custom_id="$TEST_TMP/mykey.txt"
  printf 'AGE-SECRET-KEY-1CUSTOM\n' > "$custom_id"

  run _secrets_unlock --identity "$custom_id"
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "secrets unlock: auto-detects gpg file when no age file present" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASS=secret\n' > "$CMD_STACK_DIR/.prod.env.gpg"

  run _secrets_unlock
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "secrets unlock: falls back to project-level encrypted file" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  # Encrypted file at project level, not stack level
  printf 'DB_PASS=secret\n' > "$CLI_ROOT/.prod.env.age"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$HOME/.age/key.txt"

  run _secrets_unlock
  [ "$status" -eq 0 ]
  [ -f "$CLI_ROOT/.prod.env" ]
}

@test "secrets push: hints unlock when plaintext missing but locked file exists" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'encrypted-content\n' > "$CMD_STACK_DIR/.prod.env.age"

  run _secrets_push
  [ "$status" -ne 0 ]
  [[ "$output" =~ "locked" ]]
  [[ "$output" =~ "unlock" ]]
}
