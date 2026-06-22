#!/usr/bin/env bats
# ==================================================
# tests/test_ssh_keygen.bats — Tests for lib/cmd_ssh_keygen.sh
# ==================================================
# Run:  bats tests/test_ssh_keygen.bats

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
  run_cmd() { echo "[dry-run] $1: ${*:2}"; }
  export -f fail ok warn log error print_banner run_cmd

  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/topology.sh"
  source "$CLI_ROOT/lib/cmd_ssh_keygen.sh"

  # Use a temp directory for generated keys (don't touch real ~/.ssh)
  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh"
}

teardown() { common_teardown; }

# ── Host resolution ──────────────────────────────────────────────────────────

@test "_ssh_keygen_resolve_host: resolves from topology" {
  # Set up a minimal topology
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=([harbor]="gfargo@harbor.local:22 ~/.ssh/id_rsa")
  declare -gA _TOPO_STACK_HOST=([my-app]="harbor")

  _ssh_keygen_resolve_host "my-app"
  [ "$_KEYGEN_HOST" = "harbor.local" ]
  [ "$_KEYGEN_HOST_ALIAS" = "harbor" ]
  [ "$_KEYGEN_USER" = "gfargo" ]
}

@test "_ssh_keygen_resolve_host: resolves host alias directly" {
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=([compass]="admin@compass.local:22 ~/.ssh/id_ed25519")
  declare -gA _TOPO_STACK_HOST=()

  _ssh_keygen_resolve_host "compass"
  [ "$_KEYGEN_HOST" = "compass.local" ]
  [ "$_KEYGEN_HOST_ALIAS" = "compass" ]
}

@test "_ssh_keygen_resolve_host: falls back to VPS_HOST" {
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()
  export VPS_HOST="10.0.0.5"
  export VPS_USER="deploy"

  _ssh_keygen_resolve_host "unknown-stack"
  [ "$_KEYGEN_HOST" = "10.0.0.5" ]
  [ "$_KEYGEN_USER" = "deploy" ]
  [ "$_KEYGEN_HOST_ALIAS" = "10.0.0.5" ]
}

@test "_ssh_keygen_resolve_host: returns 1 when no host found" {
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()
  unset VPS_HOST

  run _ssh_keygen_resolve_host "no-host"
  [ "$status" -ne 0 ]
}

# ── Key generation ───────────────────────────────────────────────────────────

@test "cmd_ssh_keygen: generates ed25519 key with correct naming" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  echo "VPS_HOST=testhost" > "$CMD_ENV_FILE"
  echo "VPS_USER=deploy" >> "$CMD_ENV_FILE"

  # Stub topology — force fallback to VPS_HOST by pre-loading empty topology
  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  cmd_ssh_keygen --name ci --no-authorize
  local status=$?
  [ "$status" -eq 0 ]

  # Check key was created with correct name
  [ -f "$HOME/.ssh/strut_testhost_ci" ]
  [ -f "$HOME/.ssh/strut_testhost_ci.pub" ]
}

@test "cmd_ssh_keygen: key has correct permissions" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  echo "VPS_HOST=permhost" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  cmd_ssh_keygen --name perms-test --no-authorize

  local private_perms
  private_perms=$(stat -f '%Lp' "$HOME/.ssh/strut_permhost_perms-test" 2>/dev/null || stat -c '%a' "$HOME/.ssh/strut_permhost_perms-test" 2>/dev/null)
  [ "$private_perms" = "600" ]
}

@test "cmd_ssh_keygen: key comment follows convention" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  echo "VPS_HOST=myhost" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  cmd_ssh_keygen --name deploy-key --no-authorize

  local pubkey_content
  pubkey_content=$(cat "$HOME/.ssh/strut_myhost_deploy-key.pub")
  [[ "$pubkey_content" == *"strut-deploy/myhost/deploy-key@"* ]]
}

@test "cmd_ssh_keygen: refuses to overwrite without --force" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  echo "VPS_HOST=guardhost" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  # Generate a real key first
  cmd_ssh_keygen --name existing --no-authorize

  # Try to generate again — should fail
  run cmd_ssh_keygen --name existing --no-authorize
  [ "$status" -ne 0 ]
}

@test "cmd_ssh_keygen: --force overwrites existing key" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  echo "VPS_HOST=forcehost" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  # Generate a real key first
  cmd_ssh_keygen --name overwrite --no-authorize
  local original_fp
  original_fp=$(ssh-keygen -lf "$HOME/.ssh/strut_forcehost_overwrite.pub" | awk '{print $2}')

  # Force regenerate
  cmd_ssh_keygen --name overwrite --no-authorize --force
  local new_fp
  new_fp=$(ssh-keygen -lf "$HOME/.ssh/strut_forcehost_overwrite.pub" | awk '{print $2}')

  # Fingerprints should differ (new key)
  [ "$original_fp" != "$new_fp" ]
}

@test "cmd_ssh_keygen: --dry-run generates no key" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="true"
  echo "VPS_HOST=dryhost" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  run cmd_ssh_keygen --name dry-test
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.ssh/strut_dryhost_dry-test" ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_ssh_keygen: fails without --name" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"

  run cmd_ssh_keygen
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required --name"* ]] || [[ "${lines[*]}" == *"Missing required --name"* ]]
}

@test "cmd_ssh_keygen: rejects invalid key type" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"

  run cmd_ssh_keygen --name test --type dsa
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid key type"* ]] || [[ "${lines[*]}" == *"Invalid key type"* ]]
}

@test "cmd_ssh_keygen: rsa type generates 4096-bit key" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  echo "VPS_HOST=rsahost" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  cmd_ssh_keygen --name rsa-test --type rsa --no-authorize
  [ -f "$HOME/.ssh/strut_rsahost_rsa-test" ]

  # Check it's actually RSA
  local key_info
  key_info=$(ssh-keygen -lf "$HOME/.ssh/strut_rsahost_rsa-test.pub")
  [[ "$key_info" == *"4096"* ]]
}

@test "cmd_ssh_keygen: --output stdout prints private key" {
  export CMD_STACK="my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  echo "VPS_HOST=stdouthost" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(cmd_ssh_keygen --name stdout-test --no-authorize --output stdout 2>&1)
  [[ "$output" == *"BEGIN"* ]]
  [[ "$output" == *"PRIVATE KEY"* ]]
}

@test "cmd_ssh_keygen: topology-based host resolution uses host alias in key name" {
  export CMD_STACK="homepage"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  touch "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=([harbor]="gfargo@harbor.local:22")
  declare -gA _TOPO_STACK_HOST=([homepage]="harbor")

  cmd_ssh_keygen --name ci --no-authorize
  # Key uses host alias "harbor", not the stack name
  [ -f "$HOME/.ssh/strut_harbor_ci" ]
}
