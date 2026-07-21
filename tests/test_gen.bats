#!/usr/bin/env bats
# ==================================================
# tests/test_gen.bats — Tests for `strut <stack> gen <VAR>` (lib/cmd_gen.sh)
# ==================================================
# Run:  bats tests/test_gen.bats

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

  source "$CLI_ROOT/lib/topology.sh"
  source "$CLI_ROOT/lib/secrets_providers.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"
  source "$CLI_ROOT/lib/cmd_gen.sh"

  # Fake age: copies input->output for both -e and -d, ignores other flags
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

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh" "$HOME/.age"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$HOME/.age/key.txt"

  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CMD_STACK_DIR"
  printf 'age1testkey\n' > "$CMD_STACK_DIR/.strut-recipients"
}

teardown() { common_teardown; }

_gen_path_host() { echo "$CMD_STACK_DIR/env/hosts/$1.gen.enc.env"; }
_gen_path_stack() { echo "$CMD_STACK_DIR/env/stack.gen.enc.env"; }

# ── Basic usage / validation ─────────────────────────────────────────────────

@test "gen_if_absent: fails with no VAR given" {
  run gen_if_absent
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage: strut" ]]
}

@test "gen_if_absent: rejects a lowercase/invalid VAR name" {
  run gen_if_absent --host compass not_a_valid_name
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Invalid VAR" ]]
}

@test "gen_if_absent: rejects an unknown --scope" {
  run gen_if_absent --host compass --scope bogus JWT_SECRET
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown --scope" ]]
}

@test "gen_if_absent: rejects an unknown --recipe" {
  run gen_if_absent --host compass --recipe bogus JWT_SECRET
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown --recipe" ]]
}

@test "gen_if_absent: fails when host scope can't resolve a host alias" {
  run gen_if_absent JWT_SECRET
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Could not resolve a host alias" ]]
}

# ── Generation ────────────────────────────────────────────────────────────────

@test "gen_if_absent: generates VAR when absent (host scope)" {
  run gen_if_absent --host compass JWT_SECRET
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Generated JWT_SECRET" ]]

  local enc_file
  enc_file="$(_gen_path_host compass)"
  [ -f "$enc_file" ]
  grep -q "^JWT_SECRET=" "$enc_file"

  # hex32 -> openssl rand -hex 32 -> 64 hex chars
  local val
  val=$(grep "^JWT_SECRET=" "$enc_file" | cut -d= -f2-)
  [ "${#val}" -eq 64 ]
  [[ "$val" =~ ^[0-9a-f]+$ ]]
}

@test "gen_if_absent: output file is not plaintext-obviously-named and lives under env/hosts" {
  run gen_if_absent --host compass JWT_SECRET
  [ "$status" -eq 0 ]
  local enc_file
  enc_file="$(_gen_path_host compass)"
  [ -f "$enc_file" ]
  case "$enc_file" in
    */env/hosts/compass.gen.enc.env) ;;
    *) fail "unexpected path: $enc_file" ;;
  esac
}

@test "gen_if_absent: is a no-op when VAR already present" {
  run gen_if_absent --host compass JWT_SECRET
  [ "$status" -eq 0 ]
  local enc_file
  enc_file="$(_gen_path_host compass)"
  local first_val
  first_val=$(grep "^JWT_SECRET=" "$enc_file" | cut -d= -f2-)

  run gen_if_absent --host compass JWT_SECRET
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no-op" ]]

  local second_val
  second_val=$(grep "^JWT_SECRET=" "$enc_file" | cut -d= -f2-)
  [ "$first_val" = "$second_val" ]
}

@test "gen_if_absent: N repeated runs converge to one stable value (property test)" {
  local enc_file
  enc_file="$(_gen_path_host compass)"

  run gen_if_absent --host compass STABLE_VAR
  [ "$status" -eq 0 ]
  local baseline
  baseline=$(grep "^STABLE_VAR=" "$enc_file" | cut -d= -f2-)
  [ -n "$baseline" ]

  local i
  for i in $(seq 1 20); do
    run gen_if_absent --host compass STABLE_VAR
    [ "$status" -eq 0 ]
    local current
    current=$(grep "^STABLE_VAR=" "$enc_file" | cut -d= -f2-)
    [ "$current" = "$baseline" ]
  done
}

@test "gen_if_absent: adds a second VAR alongside an existing one without disturbing it" {
  run gen_if_absent --host compass FIRST_VAR
  [ "$status" -eq 0 ]
  local enc_file
  enc_file="$(_gen_path_host compass)"
  local first_val
  first_val=$(grep "^FIRST_VAR=" "$enc_file" | cut -d= -f2-)

  run gen_if_absent --host compass SECOND_VAR
  [ "$status" -eq 0 ]

  grep -q "^FIRST_VAR=${first_val}$" "$enc_file"
  grep -q "^SECOND_VAR=" "$enc_file"
}

@test "gen_if_absent: --recipe uuid generates a UUID-shaped value" {
  run gen_if_absent --host compass --recipe uuid SESSION_ID
  [ "$status" -eq 0 ]
  local enc_file
  enc_file="$(_gen_path_host compass)"
  local val
  val=$(grep "^SESSION_ID=" "$enc_file" | cut -d= -f2-)
  [[ "$val" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

@test "gen_if_absent: --scope stack writes to env/stack.gen.enc.env (no host needed)" {
  run gen_if_absent --scope stack SHARED_TOKEN
  [ "$status" -eq 0 ]
  local enc_file
  enc_file="$(_gen_path_stack)"
  [ -f "$enc_file" ]
  grep -q "^SHARED_TOKEN=" "$enc_file"
}

@test "gen_if_absent: resolves host alias from topology (_TOPO_ACTIVE_HOST_ALIAS) without --host" {
  _TOPO_ACTIVE_HOST_ALIAS="harbor"
  run gen_if_absent JWT_SECRET
  [ "$status" -eq 0 ]
  [ -f "$(_gen_path_host harbor)" ]
  _TOPO_ACTIVE_HOST_ALIAS=""
}

@test "gen_if_absent: resolves host alias from strut.conf [stacks]/[hosts] topology" {
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=([compass]="gfargo@compass.local:22 ~/.ssh/id_rsa")
  declare -gA _TOPO_STACK_HOST=([my-app]="compass")

  run gen_if_absent JWT_SECRET
  [ "$status" -eq 0 ]
  [ -f "$(_gen_path_host compass)" ]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "gen_if_absent: --dry-run writes nothing when file doesn't exist yet" {
  run gen_if_absent --host compass --dry-run JWT_SECRET
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DRY-RUN" ]]
  [ ! -f "$(_gen_path_host compass)" ]
  [ ! -d "$CMD_STACK_DIR/env" ]
}

@test "gen_if_absent: --dry-run writes nothing when the encrypted file already exists" {
  run gen_if_absent --host compass JWT_SECRET
  [ "$status" -eq 0 ]
  local enc_file
  enc_file="$(_gen_path_host compass)"
  local before
  before=$(cat "$enc_file")

  run gen_if_absent --host compass --dry-run OTHER_VAR
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DRY-RUN" ]]

  local after
  after=$(cat "$enc_file")
  [ "$before" = "$after" ]
  ! grep -q "^OTHER_VAR=" "$enc_file"
}

# ── Encrypted, not plaintext ──────────────────────────────────────────────────

@test "gen_if_absent: the persisted file is produced via the encryption backend, not a raw copy" {
  # A distinguishable fake backend that clearly transforms content, so a test
  # asserting encryption can't be satisfied by an identity/no-op mock.
  age() {
    local output="" input=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -e) shift ;;
        -d) shift ;;
        -o) output="$2"; shift 2 ;;
        -R) shift 2 ;;
        -i) shift 2 ;;
        *)  input="$1"; shift ;;
      esac
    done
    if [ -n "$output" ] && [ -n "$input" ]; then
      { echo "ENCRYPTED:"; cat "$input"; } > "$output"
    fi
  }
  export -f age

  run gen_if_absent --host compass JWT_SECRET
  [ "$status" -eq 0 ]
  local enc_file
  enc_file="$(_gen_path_host compass)"
  [ -f "$enc_file" ]
  [ "$(head -1 "$enc_file")" = "ENCRYPTED:" ]
  # The plaintext line is still present further down (this fake backend just
  # wraps it), but the raw file is no longer byte-identical to a plain
  # "VAR=value" env file — proving it went through the encrypt step at all.
  [ "$(wc -l < "$enc_file")" -eq 2 ]
}
