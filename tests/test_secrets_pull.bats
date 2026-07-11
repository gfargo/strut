#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_pull.bats — Tests for `secrets pull`
# ==================================================
# Run:  bats tests/test_secrets_pull.bats
# Covers strut#357: pull must write to the same stack-level path push/diff/
# status prefer, not unconditionally to the project root — otherwise pulling
# for stack B silently overwrites stack A's downloaded env at the same
# project-root path in a multi-stack project.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

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

  build_ssh_opts() { echo "-o BatchMode=yes"; }
  ssh() { return 0; }  # remote file exists, by default
  scp() { echo "remote-content" > "${@: -1}"; return 0; }  # "download" writes to the last arg
  export -f build_ssh_opts ssh scp

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh"

  export CLI_ROOT="$TEST_TMP"
  export CMD_STACK="my-app"
  export CMD_STACK_DIR="$TEST_TMP/stacks/my-app"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"

  export VPS_HOST="vps.example.com"
  export VPS_USER="deploy"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()
}

teardown() { common_teardown; }

@test "secrets pull: new file defaults to the stack-level path, not project root" {
  run _secrets_pull
  [ "$status" -eq 0 ]

  [ -f "$CMD_STACK_DIR/.prod.env" ]
  [ ! -f "$CLI_ROOT/.prod.env" ]
}

@test "secrets pull: two different stacks don't clobber each other's env" {
  export CMD_STACK="app-a"
  export CMD_STACK_DIR="$TEST_TMP/stacks/app-a"
  mkdir -p "$CMD_STACK_DIR"
  scp() { echo "app-a-secrets" > "${@: -1}"; return 0; }
  export -f scp
  run _secrets_pull
  [ "$status" -eq 0 ]

  export CMD_STACK="app-b"
  export CMD_STACK_DIR="$TEST_TMP/stacks/app-b"
  mkdir -p "$CMD_STACK_DIR"
  scp() { echo "app-b-secrets" > "${@: -1}"; return 0; }
  export -f scp
  run _secrets_pull
  [ "$status" -eq 0 ]

  [ -f "$TEST_TMP/stacks/app-a/.prod.env" ]
  [ -f "$TEST_TMP/stacks/app-b/.prod.env" ]
  [ "$(cat "$TEST_TMP/stacks/app-a/.prod.env")" = "app-a-secrets" ]
  [ "$(cat "$TEST_TMP/stacks/app-b/.prod.env")" = "app-b-secrets" ]
}

@test "secrets pull: reuses an existing project-level file (backward compat)" {
  printf 'EXISTING=1\n' > "$CLI_ROOT/.prod.env"
  chmod 600 "$CLI_ROOT/.prod.env"

  run _secrets_pull --force
  [ "$status" -eq 0 ]

  [ -f "$CLI_ROOT/.prod.env" ]
  [ ! -f "$CMD_STACK_DIR/.prod.env" ]
}

@test "secrets pull: prefers an existing stack-level file over project-level" {
  printf 'STACK_LEVEL=1\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 600 "$CMD_STACK_DIR/.prod.env"
  printf 'PROJECT_LEVEL=1\n' > "$CLI_ROOT/.prod.env"
  chmod 600 "$CLI_ROOT/.prod.env"

  run _secrets_pull --force
  [ "$status" -eq 0 ]

  [ "$(cat "$CMD_STACK_DIR/.prod.env")" = "remote-content" ]
  [ "$(cat "$CLI_ROOT/.prod.env")" = "PROJECT_LEVEL=1" ]
}

@test "secrets pull: round-trips with push's read location" {
  # push reads via _secrets_resolve_local_env; pull's write target for a new
  # file must resolve to the exact same path.
  local push_would_read
  push_would_read=$(_secrets_resolve_local_env "$CMD_STACK_DIR" "prod" 2>/dev/null || echo "$CMD_STACK_DIR/.prod.env")

  run _secrets_pull
  [ "$status" -eq 0 ]

  [ -f "$push_would_read" ]
}
