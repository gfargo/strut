#!/usr/bin/env bats
# ==================================================
# tests/test_gateway.bats — Tests for lib/cmd_gateway.sh
# ==================================================
# Run:  bats tests/test_gateway.bats
# Covers: _gateway_find_caddyfile, _usage_gateway, cmd_gateway dispatch,
#         _gateway_deploy dry-run, _gateway_validate

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "BANNER: $*"; }
  run_cmd() { echo "RUN: $*"; }
  export -f fail ok warn log error print_banner run_cmd

  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  export -f build_ssh_opts

  source "$CLI_ROOT/lib/cmd_gateway.sh"

  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
}

teardown() { common_teardown; }

# ── _usage_gateway ────────────────────────────────────────────────────────────

@test "_usage_gateway: prints usage" {
  run _usage_gateway
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"reload"* ]]
  [[ "$output" == *"validate"* ]]
  [[ "$output" == *"--host"* ]]
}

# ── _gateway_find_caddyfile ───────────────────────────────────────────────────

@test "_gateway_find_caddyfile: finds host-specific Caddyfile" {
  mkdir -p "$TEST_TMP/stacks/gateway"
  touch "$TEST_TMP/stacks/gateway/Caddyfile.harbor"

  result=$(_gateway_find_caddyfile "harbor")
  [ "$result" = "$TEST_TMP/stacks/gateway/Caddyfile.harbor" ]
}

@test "_gateway_find_caddyfile: falls back to shared Caddyfile" {
  mkdir -p "$TEST_TMP/stacks/gateway"
  touch "$TEST_TMP/stacks/gateway/Caddyfile"

  result=$(_gateway_find_caddyfile "unknown-host")
  [ "$result" = "$TEST_TMP/stacks/gateway/Caddyfile" ]
}

@test "_gateway_find_caddyfile: prefers host-specific over shared" {
  mkdir -p "$TEST_TMP/stacks/gateway"
  touch "$TEST_TMP/stacks/gateway/Caddyfile.harbor"
  touch "$TEST_TMP/stacks/gateway/Caddyfile"

  result=$(_gateway_find_caddyfile "harbor")
  [ "$result" = "$TEST_TMP/stacks/gateway/Caddyfile.harbor" ]
}

@test "_gateway_find_caddyfile: returns 1 when nothing found" {
  mkdir -p "$TEST_TMP/stacks/gateway"
  # No Caddyfile at all
  run _gateway_find_caddyfile "orphan"
  [ "$status" -eq 1 ]
}

@test "_gateway_find_caddyfile: returns 1 when gateway dir missing" {
  run _gateway_find_caddyfile "harbor"
  [ "$status" -eq 1 ]
}

# ── cmd_gateway dispatch ──────────────────────────────────────────────────────

@test "cmd_gateway: no subcommand shows usage" {
  run cmd_gateway
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "cmd_gateway: help shows usage" {
  run cmd_gateway help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "cmd_gateway: unknown subcommand fails" {
  run cmd_gateway badcmd
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown gateway subcommand"* ]]
}

# ── _gateway_deploy dry-run ───────────────────────────────────────────────────

@test "_gateway_deploy: dry-run shows execution plan" {
  mkdir -p "$TEST_TMP/stacks/gateway"
  echo "localhost:80" > "$TEST_TMP/stacks/gateway/Caddyfile.harbor"

  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"

  run _gateway_deploy --host harbor --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]
  [[ "$output" == *"Caddyfile"* ]]
  [[ "$output" == *"Reload Caddy"* ]]
}

@test "_gateway_deploy: fails without --host" {
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run _gateway_deploy --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]] || [[ "$output" == *"--host"* ]]
}

@test "_gateway_deploy: fails when no Caddyfile found" {
  mkdir -p "$TEST_TMP/stacks/gateway"

  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run _gateway_deploy --host orphan --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"No Caddyfile found"* ]]
}

# ── _gateway_validate ─────────────────────────────────────────────────────────

@test "_gateway_validate: fails when gateway dir missing" {
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run _gateway_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "_gateway_validate: warns when caddy not installed" {
  mkdir -p "$TEST_TMP/stacks/gateway"
  echo "localhost" > "$TEST_TMP/stacks/gateway/Caddyfile"

  # Override command to simulate caddy not installed
  command() {
    if [[ "$2" == "caddy" ]]; then return 1; fi
    builtin command "$@"
  }
  export -f command

  run _gateway_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"caddy not installed"* ]]
}

@test "_gateway_validate: warns when no Caddyfile found" {
  mkdir -p "$TEST_TMP/stacks/gateway"
  # Empty directory — no Caddyfile

  # Stub caddy as available
  caddy() { return 0; }
  export -f caddy

  run _gateway_validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Caddyfile"* ]]
}
