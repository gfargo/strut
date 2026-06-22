#!/usr/bin/env bats
# ==================================================
# tests/test_ci_init.bats — Tests for lib/cmd_ci_init.sh
# ==================================================
# Run:  bats tests/test_ci_init.bats

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
  source "$CLI_ROOT/lib/cmd_secrets.sh"
  source "$CLI_ROOT/lib/cmd_ci_init.sh"

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh"
}

teardown() { common_teardown; }

# ── Provider detection ────────────────────────────────────────────────────────

@test "_ci_detect_provider: detects github from .github directory" {
  export PROJECT_ROOT="$TEST_TMP/project"
  export CLI_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.github/workflows"

  result=$(_ci_detect_provider)
  [ "$result" = "github" ]
}

@test "_ci_detect_provider: detects gitlab from .gitlab-ci.yml" {
  export PROJECT_ROOT="$TEST_TMP/project"
  export CLI_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT"
  touch "$PROJECT_ROOT/.gitlab-ci.yml"

  result=$(_ci_detect_provider)
  [ "$result" = "gitlab" ]
}

@test "_ci_detect_provider: falls back to manual" {
  export PROJECT_ROOT="$TEST_TMP/empty-project"
  export CLI_ROOT="$TEST_TMP/empty-project"
  mkdir -p "$PROJECT_ROOT"

  result=$(_ci_detect_provider)
  [ "$result" = "manual" ]
}

# ── Deploy key discovery ──────────────────────────────────────────────────────

@test "_ci_find_deploy_key: finds exact key name" {
  touch "$HOME/.ssh/strut_harbor_ci"

  result=$(_ci_find_deploy_key "harbor" "ci")
  [ "$result" = "$HOME/.ssh/strut_harbor_ci" ]
}

@test "_ci_find_deploy_key: finds any strut key for host" {
  touch "$HOME/.ssh/strut_harbor_github-actions"

  result=$(_ci_find_deploy_key "harbor" "ci")
  [ "$result" = "$HOME/.ssh/strut_harbor_github-actions" ]
}

@test "_ci_find_deploy_key: returns 1 when no key exists" {
  run _ci_find_deploy_key "nohost" "ci"
  [ "$status" -ne 0 ]
}

# ── Secret discovery ──────────────────────────────────────────────────────────

@test "_ci_discover_secrets: includes AUTO secrets from topology" {
  local stack_dir="$TEST_TMP/stacks/my-app"
  mkdir -p "$stack_dir"
  local env_file="$TEST_TMP/.prod.env"
  touch "$env_file"

  result=$(_ci_discover_secrets "my-app" "$stack_dir" "$env_file" "harbor" "gfargo" "harbor.local" "22" "ci")
  [[ "$result" == *"DEPLOY_HOST"*"AUTO"*"harbor.local"* ]]
  [[ "$result" == *"DEPLOY_USER"*"AUTO"*"gfargo"* ]]
  [[ "$result" == *"DEPLOY_STACK"*"AUTO"*"my-app"* ]]
}

@test "_ci_discover_secrets: includes KEY when deploy key exists" {
  local stack_dir="$TEST_TMP/stacks/my-app"
  mkdir -p "$stack_dir"
  local env_file="$TEST_TMP/.prod.env"
  touch "$env_file"
  touch "$HOME/.ssh/strut_harbor_ci"

  result=$(_ci_discover_secrets "my-app" "$stack_dir" "$env_file" "harbor" "gfargo" "harbor.local" "22" "ci")
  [[ "$result" == *"DEPLOY_SSH_KEY"*"KEY"* ]]
}

@test "_ci_discover_secrets: marks key as MANUAL when missing" {
  local stack_dir="$TEST_TMP/stacks/my-app"
  mkdir -p "$stack_dir"
  local env_file="$TEST_TMP/.prod.env"
  touch "$env_file"

  result=$(_ci_discover_secrets "my-app" "$stack_dir" "$env_file" "harbor" "gfargo" "harbor.local" "22" "ci")
  [[ "$result" == *"DEPLOY_SSH_KEY"*"MANUAL"* ]]
}

@test "_ci_discover_secrets: reads ci_secrets manifest" {
  local stack_dir="$TEST_TMP/stacks/my-app"
  mkdir -p "$stack_dir"
  local env_file="$TEST_TMP/.prod.env"
  printf 'TRIGGER_API_URL=https://api.example.com\nSTRIPE_KEY=sk_live_xxx\n' > "$env_file"
  printf 'TRIGGER_API_URL\nSTRIPE_KEY\n' > "$stack_dir/ci_secrets"

  result=$(_ci_discover_secrets "my-app" "$stack_dir" "$env_file" "harbor" "gfargo" "harbor.local" "22" "ci")
  [[ "$result" == *"TRIGGER_API_URL"*"ENV"*"https://api.example.com"* ]]
  [[ "$result" == *"STRIPE_KEY"*"ENV"*"sk_live_xxx"* ]]
}

@test "_ci_discover_secrets: ci_secrets with missing vars become MANUAL" {
  local stack_dir="$TEST_TMP/stacks/my-app"
  mkdir -p "$stack_dir"
  local env_file="$TEST_TMP/.prod.env"
  echo "ONLY_THIS=value" > "$env_file"
  printf 'ONLY_THIS\nMISSING_VAR\n' > "$stack_dir/ci_secrets"

  result=$(_ci_discover_secrets "my-app" "$stack_dir" "$env_file" "harbor" "gfargo" "harbor.local" "22" "ci")
  [[ "$result" == *"ONLY_THIS"*"ENV"* ]]
  [[ "$result" == *"MISSING_VAR"*"MANUAL"* ]]
}

@test "_ci_discover_secrets: suggests Tailscale for .ts.net hosts" {
  local stack_dir="$TEST_TMP/stacks/my-app"
  mkdir -p "$stack_dir"
  local env_file="$TEST_TMP/.prod.env"
  touch "$env_file"

  result=$(_ci_discover_secrets "my-app" "$stack_dir" "$env_file" "harbor" "gfargo" "harbor.tail1234.ts.net" "22" "ci")
  [[ "$result" == *"TS_OAUTH_CLIENT_ID"*"MANUAL"* ]]
  [[ "$result" == *"TS_OAUTH_SECRET"*"MANUAL"* ]]
}

# ── Command handler ───────────────────────────────────────────────────────────

@test "cmd_ci_init: dry-run shows checklist without pushing" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export CMD_ENV_NAME="prod"
  export DRY_RUN="true"
  export PROJECT_ROOT="$TEST_TMP/project"
  export CLI_ROOT="$TEST_TMP/project"
  mkdir -p "$CMD_STACK_DIR" "$PROJECT_ROOT/.github"
  echo "VPS_HOST=myhost.local" > "$CMD_ENV_FILE"
  echo "VPS_USER=deploy" >> "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  local output
  output=$(cmd_ci_init --dry-run 2>&1)
  [[ "$output" == *"CI Init"* ]]
  [[ "$output" == *"DEPLOY_HOST"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_ci_init: manual mode prints gh secret set commands" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export CMD_ENV_NAME="prod"
  export DRY_RUN="false"
  export PROJECT_ROOT="$TEST_TMP/project"
  export CLI_ROOT="$TEST_TMP/project"
  mkdir -p "$CMD_STACK_DIR" "$PROJECT_ROOT/.github"
  echo "VPS_HOST=myhost.local" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  # No gh CLI available — force manual output
  gh() { return 1; }
  export -f gh

  local output
  output=$(cmd_ci_init --provider github 2>&1)
  [[ "$output" == *"gh secret set DEPLOY_HOST"* ]]
  [[ "$output" == *"myhost.local"* ]]
}

@test "cmd_ci_init: fails with invalid provider" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export DRY_RUN="false"
  mkdir -p "$CMD_STACK_DIR"
  touch "$CMD_ENV_FILE"

  run cmd_ci_init --provider invalid
  [ "$status" -ne 0 ]
}

@test "cmd_ci_init: respects --repo flag in output" {
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export CMD_ENV_NAME="prod"
  export DRY_RUN="false"
  export PROJECT_ROOT="$TEST_TMP/project"
  export CLI_ROOT="$TEST_TMP/project"
  mkdir -p "$CMD_STACK_DIR" "$PROJECT_ROOT"
  echo "VPS_HOST=host.local" > "$CMD_ENV_FILE"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()

  gh() { return 1; }
  export -f gh

  local output
  output=$(cmd_ci_init --provider github --repo gfargo/my-app 2>&1)
  [[ "$output" == *"-R gfargo/my-app"* ]]
}
