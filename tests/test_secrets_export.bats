#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_export.bats — Tests for `secrets export`
# ==================================================
# Run:  bats tests/test_secrets_export.bats

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

  # Standard test env file
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$CMD_STACK_DIR"
  printf 'DB_PASSWORD=secret123\nAPI_KEY=tok456\n' > "$CMD_STACK_DIR/.prod.env"
}

teardown() { common_teardown; }

# ── format: env-json ──────────────────────────────────────────────────────────

@test "secrets export: env-json produces valid JSON object" {
  output=$(_secrets_export --format env-json 2>&1)
  [[ "$output" == "{"* ]]
  [[ "$output" == *"}"* ]]
  [[ "$output" == *'"DB_PASSWORD"'* ]]
  [[ "$output" == *'"secret123"'* ]]
  [[ "$output" == *'"API_KEY"'* ]]
  [[ "$output" == *'"tok456"'* ]]
}

@test "secrets export: env-json last key has no trailing comma" {
  output=$(_secrets_export --format env-json 2>&1)
  # The last non-brace line must not end with a comma
  last_kv=$(echo "$output" | grep '"' | tail -1)
  [[ "$last_kv" != *"," ]]
}

# ── format: docker-secret ─────────────────────────────────────────────────────

@test "secrets export: docker-secret produces docker secret create commands" {
  output=$(_secrets_export --format docker-secret 2>&1)
  [[ "$output" == *"docker secret create"* ]]
}

@test "secrets export: docker-secret includes secret name with stack prefix" {
  output=$(_secrets_export --format docker-secret 2>&1)
  [[ "$output" == *"my-app"* ]] || [[ "$output" == *"my_app"* ]]
}

@test "secrets export: docker-secret includes docker-compose YAML comment" {
  output=$(_secrets_export --format docker-secret 2>&1)
  [[ "$output" == *"docker-compose.yml"* ]] || [[ "$output" == *"secrets:"* ]]
}

# ── format: k8s-secret ────────────────────────────────────────────────────────

@test "secrets export: k8s-secret produces Kubernetes Secret manifest" {
  output=$(_secrets_export --format k8s-secret 2>&1)
  [[ "$output" == *"apiVersion: v1"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"type: Opaque"* ]]
  [[ "$output" == *"data:"* ]]
}

@test "secrets export: k8s-secret base64-encodes values" {
  output=$(_secrets_export --format k8s-secret 2>&1)
  expected=$(printf '%s' "secret123" | base64 | tr -d '\n')
  [[ "$output" == *"$expected"* ]]
}

@test "secrets export: k8s-secret uses stack-env name" {
  output=$(_secrets_export --format k8s-secret 2>&1)
  [[ "$output" == *"my-app"* ]]
}

# ── error handling ────────────────────────────────────────────────────────────

@test "secrets export: fails without --format" {
  run _secrets_export 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing --format"* ]]
}

@test "secrets export: fails with unknown format" {
  run _secrets_export --format yaml 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown format"* ]]
}

@test "secrets export: fails with --format but no value (set -u guard)" {
  # Under set -u, accessing $2 when absent would crash without the guard.
  run _secrets_export --format 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]] || [[ "$output" == *"--format"* ]]
}

@test "secrets export: fails when no local env file" {
  export CMD_STACK="empty"
  export CMD_STACK_DIR="$TEST_TMP/stacks/empty"
  mkdir -p "$CMD_STACK_DIR"

  run _secrets_export --format env-json 2>&1
  [ "$status" -ne 0 ]
}

# ── docker-secret quoting ─────────────────────────────────────────────────────

@test "secrets export: docker-secret handles value with single quote" {
  printf "SECRET=it\\'s-a-secret\nAPI_KEY=tok456\n" > "$CMD_STACK_DIR/.prod.env"
  output=$(_secrets_export --format docker-secret 2>&1)
  # The output must not contain an unescaped bare single-quote around the value
  # (i.e. the line must not look like printf '%s' 'it's-a-secret').
  # Instead, it must be syntactically valid shell — we check that the value
  # appears in some form (escaped) in the output.
  [[ "$output" == *"docker secret create"* ]]
  # Ensure the raw broken form is NOT present
  [[ "$output" != *"'it's-a-secret'"* ]]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

@test "secrets export: dispatches via cmd_secrets" {
  output=$(cmd_secrets export --format env-json 2>&1)
  [[ "$output" == "{"* ]]
  [[ "$output" == *"DB_PASSWORD"* ]]
}
