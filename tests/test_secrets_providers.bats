#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_providers.bats — Tests for lib/secrets_providers.sh
#                                      and `secrets hydrate`
# ==================================================
# Run:  bats tests/test_secrets_providers.bats
# Covers: secrets_reference_scheme, secrets_is_reference,
#         secrets_reference_target, secrets_provider_available,
#         secrets_resolve_reference, exec/file/vault providers,
#         _secrets_hydrate (template -> .env, dry-run, --force, fail-fast)

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers so they don't exit the runner.
  fail()  { echo "FAIL: $1" >&2; return 1; }
  ok()    { echo "OK: $*"; }
  warn()  { echo "WARN: $*" >&2; }
  log()   { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "== $* =="; }
  export -f fail ok warn log error print_banner

  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/secrets_providers.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"
}

teardown() { common_teardown; }

# ── secrets_reference_scheme ──────────────────────────────────────────────────

@test "secrets_reference_scheme: detects registered schemes" {
  run secrets_reference_scheme "vault://myapp.db-password"
  [ "$status" -eq 0 ]; [ "$output" = "vault" ]
  run secrets_reference_scheme "exec://aws secretsmanager get x"
  [ "$status" -eq 0 ]; [ "$output" = "exec" ]
  run secrets_reference_scheme "file:///run/secrets/token"
  [ "$status" -eq 0 ]; [ "$output" = "file" ]
}

@test "secrets_reference_scheme: literals and unknown schemes are not references" {
  run secrets_reference_scheme "hunter2"
  [ "$status" -ne 0 ]
  # A normal connection string must NOT be mistaken for a reference.
  run secrets_reference_scheme "postgres://user:pass@host:5432/db"
  [ "$status" -ne 0 ]
  run secrets_reference_scheme "https://example.com"
  [ "$status" -ne 0 ]
}

@test "secrets_is_reference: boolean wrapper" {
  secrets_is_reference "vault://x"
  ! secrets_is_reference "plain"
}

@test "secrets_reference_target: strips the scheme prefix" {
  run secrets_reference_target "vault://myapp.db-password"
  [ "$output" = "myapp.db-password" ]
  run secrets_reference_target "exec://cat /run/secrets/x"
  [ "$output" = "cat /run/secrets/x" ]
}

# ── exec:// and file:// providers ─────────────────────────────────────────────

@test "secrets_provider__exec: returns command stdout, trimmed" {
  run secrets_provider__exec "printf 'super-secret\n'"
  [ "$status" -eq 0 ]; [ "$output" = "super-secret" ]
}

@test "secrets_provider__exec: non-zero command fails" {
  run secrets_provider__exec "exit 3"
  [ "$status" -ne 0 ]
}

@test "secrets_provider__file: returns file contents, trimmed" {
  printf 'file-secret\n' > "$TEST_TMP/s"
  run secrets_provider__file "$TEST_TMP/s"
  [ "$status" -eq 0 ]; [ "$output" = "file-secret" ]
}

@test "secrets_provider__file: missing file fails" {
  run secrets_provider__file "$TEST_TMP/nope"
  [ "$status" -ne 0 ]
}

# ── vault:// provider (with a fake `bw`) ──────────────────────────────────────

@test "secrets_provider__vault: reads the password field via bw" {
  bw() { [ "$1" = "get" ] && [ "$2" = "password" ] && echo "vw-password"; }
  export -f bw
  run secrets_provider__vault "myapp.db-password"
  [ "$status" -eq 0 ]; [ "$output" = "vw-password" ]
}

@test "secrets_provider__vault: falls back to notes when no password" {
  bw() {
    [ "$1" = "get" ] && [ "$2" = "password" ] && return 1
    [ "$1" = "get" ] && [ "$2" = "notes" ] && echo "vw-note-secret"
  }
  export -f bw
  run secrets_provider__vault "myapp.token"
  [ "$status" -eq 0 ]; [ "$output" = "vw-note-secret" ]
}

@test "secrets_provider__vault_check: fails without a session" {
  bw() { :; }; export -f bw
  unset BW_SESSION BW_CLIENTID
  run secrets_provider__vault_check
  [ "$status" -ne 0 ]
}

@test "secrets_provider__vault_check: passes with BW_SESSION + bw present" {
  bw() { :; }; export -f bw
  export BW_SESSION="fake"
  run secrets_provider__vault_check
  [ "$status" -eq 0 ]
}

# ── secrets_resolve_reference ─────────────────────────────────────────────────

@test "secrets_resolve_reference: literal passes through unchanged" {
  run secrets_resolve_reference "just-a-value"
  [ "$status" -eq 0 ]; [ "$output" = "just-a-value" ]
}

@test "secrets_resolve_reference: dispatches to the right provider" {
  printf 'abc\n' > "$TEST_TMP/v"
  run secrets_resolve_reference "file://$TEST_TMP/v"
  [ "$status" -eq 0 ]; [ "$output" = "abc" ]
}

# ── _secrets_hydrate (end to end) ─────────────────────────────────────────────

_setup_stack() {
  export CLI_ROOT_SAVE="$CLI_ROOT"
  export CMD_STACK="myapp"
  export CMD_STACK_DIR="$TEST_TMP/stacks/myapp"
  export CMD_ENV_NAME="prod"
  export DRY_RUN="false"
  mkdir -p "$CMD_STACK_DIR"
}

@test "_secrets_hydrate: resolves references and copies literals" {
  _setup_stack
  printf 'file-val\n' > "$TEST_TMP/secret_file"
  cat > "$CMD_STACK_DIR/.prod.env.template" <<EOF
# connection (literal)
VPS_HOST=1.2.3.4
DATABASE_URL=postgres://u:p@h:5432/db
# secrets (resolved)
API_TOKEN=exec://printf 'tok-123'
TLS_KEY=file://$TEST_TMP/secret_file
EOF

  run _secrets_hydrate
  [ "$status" -eq 0 ]

  local out="$CMD_STACK_DIR/.prod.env"
  [ -f "$out" ]
  grep -q '^VPS_HOST=1.2.3.4$' "$out"
  grep -q '^DATABASE_URL=postgres://u:p@h:5432/db$' "$out"
  grep -q '^API_TOKEN=tok-123$' "$out"
  grep -q '^TLS_KEY=file-val$' "$out"
  # comments preserved
  grep -q '^# connection (literal)$' "$out"
}

@test "_secrets_hydrate: output file is mode 600" {
  _setup_stack
  printf 'API_TOKEN=exec://printf x\n' > "$CMD_STACK_DIR/.prod.env.template"
  run _secrets_hydrate
  [ "$status" -eq 0 ]
  local perms
  perms=$(stat -c '%a' "$CMD_STACK_DIR/.prod.env" 2>/dev/null || stat -f '%Lp' "$CMD_STACK_DIR/.prod.env")
  [ "$perms" = "600" ]
}

@test "_secrets_hydrate: dry-run writes no file" {
  _setup_stack
  export DRY_RUN="true"
  printf 'API_TOKEN=exec://printf x\n' > "$CMD_STACK_DIR/.prod.env.template"
  run _secrets_hydrate
  [ "$status" -eq 0 ]
  [ ! -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "_secrets_hydrate: dry-run previews without provider credentials" {
  # A vault:// ref must be previewable even with no bw/session — dry-run must
  # not pre-flight providers.
  _setup_stack
  export DRY_RUN="true"
  bw() { return 1; }; export -f bw          # bw present but unusable
  unset BW_SESSION BW_CLIENTID
  printf 'DB_PASS=vault://my-app.db-password\n' > "$CMD_STACK_DIR/.prod.env.template"
  run _secrets_hydrate
  [ "$status" -eq 0 ]
  [ ! -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "_secrets_hydrate: rejects a multi-line secret, no file written" {
  _setup_stack
  printf -- '-----BEGIN KEY-----\nabc\n-----END KEY-----\n' > "$TEST_TMP/pem"
  printf 'TLS_KEY=file://%s\n' "$TEST_TMP/pem" > "$CMD_STACK_DIR/.prod.env.template"
  run _secrets_hydrate
  [ "$status" -ne 0 ]
  [ ! -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "_secrets_hydrate: refuses to overwrite without --force" {
  _setup_stack
  printf 'API_TOKEN=exec://printf x\n' > "$CMD_STACK_DIR/.prod.env.template"
  echo "OLD=1" > "$CMD_STACK_DIR/.prod.env"
  run _secrets_hydrate
  [ "$status" -ne 0 ]
  grep -q '^OLD=1$' "$CMD_STACK_DIR/.prod.env"   # untouched
}

@test "_secrets_hydrate: --force overwrites" {
  _setup_stack
  printf 'API_TOKEN=exec://printf new\n' > "$CMD_STACK_DIR/.prod.env.template"
  echo "OLD=1" > "$CMD_STACK_DIR/.prod.env"
  run _secrets_hydrate --force
  [ "$status" -eq 0 ]
  grep -q '^API_TOKEN=new$' "$CMD_STACK_DIR/.prod.env"
  ! grep -q '^OLD=1$' "$CMD_STACK_DIR/.prod.env"
}

@test "_secrets_hydrate: missing template fails cleanly" {
  _setup_stack
  run _secrets_hydrate
  [ "$status" -ne 0 ]
}

@test "_secrets_hydrate: fail-fast leaves no partial file on bad reference" {
  _setup_stack
  cat > "$CMD_STACK_DIR/.prod.env.template" <<EOF
GOOD=exec://printf ok
BAD=file://$TEST_TMP/does-not-exist
EOF
  run _secrets_hydrate
  [ "$status" -ne 0 ]
  [ ! -f "$CMD_STACK_DIR/.prod.env" ]
}
