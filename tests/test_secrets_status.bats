#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_status.bats — Tests for `secrets status`
# ==================================================
# Run:  bats tests/test_secrets_status.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  fail()  { echo "FAIL: $1" >&2; return 1; }
  ok()    { echo "OK: $*"; }
  warn()  { echo "WARN: $*" >&2; }
  log()   { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "== $* =="; }
  export -f fail ok warn log error print_banner

  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/topology.sh"
  source "$CLI_ROOT/lib/secrets_providers.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"

  # Stub SSH to avoid real connections
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  ssh() { return 1; }  # Remote unreachable by default
  export -f build_ssh_opts ssh

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh"
}

teardown() { common_teardown; }

# ── Basic output ──────────────────────────────────────────────────────────────

@test "secrets status: shows local env info when file exists" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"

  printf 'VPS_HOST=test\nDB_PASS=secret\nAPI_KEY=tok\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 600 "$CMD_STACK_DIR/.prod.env"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"Local env:"* ]]
  [[ "$output" == *"3 vars"* ]]
  [[ "$output" == *"stack-level"* ]]
}

@test "secrets status: reports missing local env" {
  export CMD_STACK="empty-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/empty-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"not found"* ]]
}

@test "secrets status: shows template info with reference counts" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"

  cat > "$CMD_STACK_DIR/.prod.env.template" <<'EOF'
VPS_HOST=10.0.0.1
DB_PASS=vault://my-app.db-password
API_TOKEN=exec://printf tok
LITERAL=value
EOF
  touch "$CMD_STACK_DIR/.prod.env"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"Template:"* ]]
  [[ "$output" == *"2 references"* ]]
  [[ "$output" == *"2 literals"* ]]
}

@test "secrets status: reports no template when missing" {
  export CMD_STACK="no-template"
  export CMD_STACK_DIR="$TEST_TMP/stacks/no-template"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"
  touch "$CMD_STACK_DIR/.prod.env"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"none found"* ]]
}

@test "secrets status: shows required_vars coverage" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"

  printf 'DB_PASS=secret\nAPI_KEY=tok\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'DB_PASS\nAPI_KEY\nMISSING_VAR\n' > "$CMD_STACK_DIR/required_vars"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"2/3 present"* ]]
  [[ "$output" == *"MISSING_VAR"* ]]
}

@test "secrets status: shows all required vars present" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"

  printf 'DB_PASS=secret\nAPI_KEY=tok\n' > "$CMD_STACK_DIR/.prod.env"
  printf 'DB_PASS\nAPI_KEY\n' > "$CMD_STACK_DIR/required_vars"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"2/2 present ✓"* ]]
}

@test "secrets status: shows deploy key info" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"
  touch "$CMD_STACK_DIR/.prod.env"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=([harbor]="gfargo@harbor.local:22")
  declare -gA _TOPO_STACK_HOST=([my-app]="harbor")

  # Create a deploy key
  touch "$HOME/.ssh/strut_harbor_ci"

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"Deploy keys:"*"1 found"* ]]
}

@test "secrets status: suggests ssh:keygen when no deploy key" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"
  touch "$CMD_STACK_DIR/.prod.env"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=([harbor]="gfargo@harbor.local:22")
  declare -gA _TOPO_STACK_HOST=([my-app]="harbor")

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"ssh:keygen"* ]]
}

@test "secrets status: shows remote as unreachable when SSH fails" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"
  printf 'VPS_HOST=unreachable.host\n' > "$CMD_STACK_DIR/.prod.env"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(_secrets_status 2>&1)
  [[ "$output" == *"unreachable"* ]] || [[ "$output" == *"not found"* ]]
}

@test "secrets status: dispatches via cmd_secrets" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"
  touch "$CMD_STACK_DIR/.prod.env"

  export CLI_ROOT="$TEST_TMP"
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(cmd_secrets status 2>&1)
  [[ "$output" == *"Secrets Status"* ]]
}
