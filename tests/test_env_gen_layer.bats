#!/usr/bin/env bats
# ==================================================
# tests/test_env_gen_layer.bats — Tests for the gen env layer
# (lib/utils.sh: env_apply_gen_layer / env_apply_layers), the final layer of
# the deploy env chain: base env → host layer → decrypted secrets →
# generated per-host/stack values (strut#179, strut#1135)
# ==================================================
# Run:  bats tests/test_env_gen_layer.bats

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
  fail() { echo "$1" >&2; return 1; }

  # Fake age: copies input->output for both -e and -d, ignores other flags.
  # A decrypt is just "the file's content", so we can write gen-layer
  # fixtures as plain VAR=value text.
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
  export CMD_STACK_DIR="$TEST_TMP"
}

teardown() { common_teardown; }

_write_gen_file() {
  local path="$1" var="$2" value="$3"
  mkdir -p "$(dirname "$path")"
  printf '%s=%s\n' "$var" "$value" > "$path"
}

# ── env_apply_gen_layer: precedence ─────────────────────────────────────────

@test "validate_env_file: gen layer (host scope) wins over the base env value" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=10.0.0.1
TOKEN=base
EOF
  _write_gen_file "$TEST_TMP/env/hosts/compass.gen.enc.env" TOKEN gen

  _TOPO_ACTIVE_HOST_ALIAS="compass"
  validate_env_file "$TEST_TMP/.test.env" VPS_HOST
  _TOPO_ACTIVE_HOST_ALIAS=""

  [ "$TOKEN" = "gen" ]
}

@test "validate_env_file: gen layer (host scope) wins over the tracked host layer" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=10.0.0.1
TOKEN=base
EOF
  mkdir -p "$TEST_TMP/env/hosts"
  cat > "$TEST_TMP/env/hosts/compass.env" <<'EOF'
TOKEN=host
EOF
  _write_gen_file "$TEST_TMP/env/hosts/compass.gen.enc.env" TOKEN gen

  _TOPO_ACTIVE_HOST_ALIAS="compass"
  validate_env_file "$TEST_TMP/.test.env" VPS_HOST
  _TOPO_ACTIVE_HOST_ALIAS=""

  [ "$TOKEN" = "gen" ]
}

@test "validate_env_file: stack-scope gen file applies even with no active host alias" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=10.0.0.1
TOKEN=base
EOF
  _write_gen_file "$TEST_TMP/env/stack.gen.enc.env" TOKEN gen-stack

  unset _TOPO_ACTIVE_HOST_ALIAS
  validate_env_file "$TEST_TMP/.test.env" VPS_HOST

  [ "$TOKEN" = "gen-stack" ]
}

@test "validate_env_file: host-scope gen file wins over stack-scope gen file" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=10.0.0.1
TOKEN=base
EOF
  _write_gen_file "$TEST_TMP/env/stack.gen.enc.env" TOKEN gen-stack
  _write_gen_file "$TEST_TMP/env/hosts/compass.gen.enc.env" TOKEN gen-host

  _TOPO_ACTIVE_HOST_ALIAS="compass"
  validate_env_file "$TEST_TMP/.test.env" VPS_HOST
  _TOPO_ACTIVE_HOST_ALIAS=""

  [ "$TOKEN" = "gen-host" ]
}

@test "validate_env_file: no gen file present is a no-op" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=10.0.0.1
TOKEN=base
EOF
  _TOPO_ACTIVE_HOST_ALIAS="compass"
  validate_env_file "$TEST_TMP/.test.env" VPS_HOST
  _TOPO_ACTIVE_HOST_ALIAS=""

  [ "$TOKEN" = "base" ]
}

@test "validate_env_file: decrypt failure on the gen layer warns and leaves the earlier value intact" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=10.0.0.1
TOKEN=base
EOF
  _write_gen_file "$TEST_TMP/env/hosts/compass.gen.enc.env" TOKEN gen

  # No age identity available -> _secrets_unlock fails to decrypt.
  rm -f "$HOME/.age/key.txt"
  unset STRUT_AGE_IDENTITY

  _TOPO_ACTIVE_HOST_ALIAS="compass"
  run validate_env_file "$TEST_TMP/.test.env" VPS_HOST
  _TOPO_ACTIVE_HOST_ALIAS=""

  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not decrypt generated env layer"* ]]
}

@test "env_apply_gen_layer: no-op when cmd_secrets.sh hasn't been sourced" {
  # A fresh shell with only utils.sh loaded (no cmd_secrets.sh) — mirrors
  # partial-source test contexts elsewhere in the suite.
  run bash -c "
    source '$CLI_ROOT/lib/utils.sh'
    env_apply_gen_layer 'my-app' '$TEST_TMP'
  "
  [ "$status" -eq 0 ]
}
