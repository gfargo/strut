#!/usr/bin/env bats
# ==================================================
# tests/test_cert.bats — Tests for lib/cmd_cert.sh
# ==================================================
# Run:  bats tests/test_cert.bats
# Covers: _cert_resolve_hostname, _usage_cert_renew,
#         cmd_cert_renew dry-run, cmd_cert_status dry-run

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

  source "$CLI_ROOT/lib/cmd_cert.sh"

  export CLI_ROOT="$TEST_TMP"
}

teardown() { common_teardown; }

# ── _usage_cert_renew ─────────────────────────────────────────────────────────

@test "_usage_cert_renew: prints usage" {
  run _usage_cert_renew
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"cert:renew"* ]]
  [[ "$output" == *"cert:status"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

# ── _cert_resolve_hostname ────────────────────────────────────────────────────

@test "_cert_resolve_hostname: uses TAILSCALE_HOSTNAME if set" {
  export TAILSCALE_HOSTNAME="my-node.tail12345.ts.net"
  result=$(_cert_resolve_hostname "harbor")
  [ "$result" = "my-node.tail12345.ts.net" ]
}

@test "_cert_resolve_hostname: defaults to host alias" {
  unset TAILSCALE_HOSTNAME
  result=$(_cert_resolve_hostname "harbor")
  [ "$result" = "harbor" ]
}

# ── cmd_cert_renew dry-run ────────────────────────────────────────────────────

@test "cmd_cert_renew: dry-run shows execution plan" {
  # Stub topology
  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"
  export VPS_PORT="22"

  export CMD_STACK="harbor"
  export DRY_RUN=false
  unset TAILSCALE_HOSTNAME

  run cmd_cert_renew --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]
  [[ "$output" == *"tailscale cert"* ]]
  [[ "$output" == *"Reload Caddy"* ]]
}

@test "cmd_cert_renew: dry-run shows correct cert paths" {
  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"

  export CMD_STACK="compass"
  export DRY_RUN=false
  unset TAILSCALE_HOSTNAME

  run cmd_cert_renew --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"/etc/caddy/certs/compass.crt"* ]]
  [[ "$output" == *"/etc/caddy/certs/compass.key"* ]]
}

@test "cmd_cert_renew: respects CERT_DIR override" {
  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"
  export CERT_DIR="/opt/certs"

  export CMD_STACK="harbor"
  export DRY_RUN=false
  unset TAILSCALE_HOSTNAME

  run cmd_cert_renew --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"/opt/certs/harbor.crt"* ]]
}

@test "cmd_cert_renew: fails without host alias" {
  export CMD_STACK=""
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_cert_renew --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Host alias required"* ]]
}

@test "cmd_cert_renew: fails when host cannot be resolved" {
  export CMD_STACK="unknown"
  unset VPS_HOST

  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_cert_renew --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot resolve host"* ]]
}

# ── cmd_cert_status dry-run ───────────────────────────────────────────────────

@test "cmd_cert_status: dry-run shows openssl check" {
  topology_load() { :; }
  topology_has_host() { return 1; }
  export -f topology_load topology_has_host
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"

  export CMD_STACK="harbor"
  export DRY_RUN=true
  unset TAILSCALE_HOSTNAME

  run cmd_cert_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"openssl"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_cert_status: fails without host alias" {
  export CMD_STACK=""
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_cert_status
  [ "$status" -ne 0 ]
  [[ "$output" == *"Host alias required"* ]]
}
