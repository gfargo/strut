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
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias
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
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias
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

# ── _gateway_deploy execute path ──────────────────────────────────────────────
#
# These stub ssh/scp to log every invocation to $TEST_TMP/ssh.log so ordering
# and destination paths can be asserted, following the convention in
# tests/test_cmd_domain.bats. Behavior (validate/reload exit codes) is
# controlled per-test via env vars read inside the stub.

_gateway_deploy_test_setup() {
  mkdir -p "$TEST_TMP/stacks/gateway"
  echo "localhost:80" > "$TEST_TMP/stacks/gateway/Caddyfile.harbor"

  topology_load() { :; }
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"

  : > "$TEST_TMP/ssh.log"

  scp() { echo "scp $*" >> "$TEST_TMP/ssh.log"; return 0; }
  export -f scp

  ssh() {
    local args="$*"
    echo "ssh $args" >> "$TEST_TMP/ssh.log"
    if [[ "$args" == *"caddy validate"* ]]; then
      return "${GW_TEST_VALIDATE_STATUS:-0}"
    fi
    if [[ "$args" == *"cp '"*".bak'"* ]]; then
      return "${GW_TEST_BACKUP_STATUS:-0}"
    fi
    if [[ "$args" == *"systemctl reload caddy"* ]]; then
      # Rollback-then-reload is a compound command distinguished by the mv.
      if [[ "$args" == *"mv "*".bak"* ]]; then
        return "${GW_TEST_ROLLBACK_RELOAD_STATUS:-0}"
      fi
      return "${GW_TEST_RELOAD_STATUS:-0}"
    fi
    return 0
  }
  export -f ssh
}

@test "_gateway_deploy: invalid config never reaches live path" {
  _gateway_deploy_test_setup
  export GW_TEST_VALIDATE_STATUS=1

  run _gateway_deploy --host harbor
  [ "$status" -ne 0 ]
  [[ "$output" == *"validation failed"* ]]

  # Live path is never touched — only the staging path (/tmp/Caddyfile.new) is referenced
  ! grep -q "mv '/etc/caddy/Caddyfile.new' '/etc/caddy/Caddyfile'" "$TEST_TMP/ssh.log"
  ! grep -q "cp '/etc/caddy/Caddyfile' '/etc/caddy/Caddyfile.bak'" "$TEST_TMP/ssh.log"
  [[ "$output" != *"Caddyfile installed"* ]]
}

@test "_gateway_deploy: valid config installs and reload succeeds" {
  _gateway_deploy_test_setup

  run _gateway_deploy --host harbor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Caddyfile installed"* ]]
  [[ "$output" == *"Caddy reloaded"* ]]
  [[ "$output" != *"failed"* ]]

  grep -q "caddy validate --config '/tmp/Caddyfile.new'" "$TEST_TMP/ssh.log"
  grep -q "cp '/tmp/Caddyfile.new'" "$TEST_TMP/ssh.log"
}

@test "_gateway_deploy: reload failure rolls back and reports failure" {
  _gateway_deploy_test_setup
  export GW_TEST_RELOAD_STATUS=1
  export GW_TEST_ROLLBACK_RELOAD_STATUS=0

  run _gateway_deploy --host harbor
  [ "$status" -ne 0 ]
  [[ "$output" == *"rolled back"* ]]
  [[ "$output" != *"Caddy reloaded"* ]]

  grep -q "mv '.*\.bak' '.*Caddyfile' && sudo systemctl reload caddy" "$TEST_TMP/ssh.log"
}

@test "_gateway_deploy: reload and rollback both fail reports manual intervention" {
  _gateway_deploy_test_setup
  export GW_TEST_RELOAD_STATUS=1
  export GW_TEST_ROLLBACK_RELOAD_STATUS=1

  run _gateway_deploy --host harbor
  [ "$status" -ne 0 ]
  [[ "$output" == *"manual intervention"* ]]
  [[ "$output" != *"Caddy reloaded"* ]]
}

@test "_gateway_deploy: reload failure with no prior backup reports honestly" {
  _gateway_deploy_test_setup
  export GW_TEST_BACKUP_STATUS=1
  export GW_TEST_RELOAD_STATUS=1

  run _gateway_deploy --host harbor
  [ "$status" -ne 0 ]
  [[ "$output" == *"no previous config to roll back to"* ]]
  [[ "$output" != *"rolled back"* ]]
  [[ "$output" != *"Caddy reloaded"* ]]
}

@test "_gateway_deploy: upload failure fails loud" {
  _gateway_deploy_test_setup
  scp() { echo "scp $*" >> "$TEST_TMP/ssh.log"; return 1; }
  export -f scp
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run _gateway_deploy --host harbor
  [ "$status" -ne 0 ]
  [[ "$output" == *"Upload failed"* ]]
  [[ "$output" != *"Caddyfile installed"* ]]
}
