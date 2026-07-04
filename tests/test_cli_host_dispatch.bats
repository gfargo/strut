#!/usr/bin/env bats
# ==================================================
# tests/test_cli_host_dispatch.bats — host-scoped command dispatch (#214)
# ==================================================
# Regression tests for #214 (P0): `strut gateway <subcmd> --host <alias>` was
# misrouted to the generic per-stack handlers (COMMAND shadowed STACK in the
# entrypoint's dispatch case), and `strut <host> provision|cert:*` always fell
# through to the VPS_HOST env-var fallback because the handlers called
# topology_has_host (stack→host mapping) instead of topology_is_host_alias
# ([hosts] membership).
#
# These tests drive the real entrypoint with `bash "$CLI" ...`, not just the
# lib functions directly, so a regression in dispatch wiring is caught here
# even if the function-level tests (test_gateway.bats, test_cert.bats,
# test_provision.bats) still pass.
#
# Run:  bats tests/test_cli_host_dispatch.bats

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# _make_project <dir> — strut.conf with a [hosts] alias so host-scoped
# commands can resolve a target without falling back to VPS_HOST.
_make_project() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/strut.conf" <<'EOF'
REGISTRY_TYPE=none
DEFAULT_ORG=test
BANNER_TEXT=test

[hosts]
harbor = ubuntu@1.2.3.4:22
EOF
}

# _run_in <dir> <args...>
_run_in() {
  local dir="$1"; shift
  run env -i \
    HOME="$TEST_TMP/home" \
    PATH="$PATH" \
    PWD="$dir" \
    bash -c "cd '$dir' && bash '$CLI' \"\$@\"" _ "$@"
}

# ── strut gateway <subcommand> --host <alias> ────────────────────────────────

@test "strut gateway deploy --host reaches _gateway_deploy, not generic cmd_deploy" {
  local proj="$TEST_TMP/gw-deploy"
  _make_project "$proj"
  mkdir -p "$proj/stacks/gateway"
  echo "example.com { respond ok }" > "$proj/stacks/gateway/Caddyfile.harbor"

  _run_in "$proj" gateway deploy --host harbor --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Gateway Deploy: harbor"* ]]
  [[ "$output" == *"[DRY-RUN] No changes made."* ]]
  [[ "$output" != *"Compose file not found"* ]]
}

@test "strut gateway status --host reaches _gateway_status, not generic cmd_status" {
  local proj="$TEST_TMP/gw-status"
  _make_project "$proj"
  mkdir -p "$proj/stacks/gateway"

  _run_in "$proj" gateway status --host harbor --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Check Caddy service status"* ]]
  [[ "$output" != *"Env file not found"* ]]
}

@test "strut gateway reload --host reaches _gateway_reload" {
  local proj="$TEST_TMP/gw-reload"
  _make_project "$proj"
  mkdir -p "$proj/stacks/gateway"

  _run_in "$proj" gateway reload --host harbor --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Reload Caddy"* ]]
  [[ "$output" != *"Env file not found"* ]]
}

@test "strut gateway --help prints gateway usage" {
  local proj="$TEST_TMP/gw-help"
  _make_project "$proj"

  _run_in "$proj" gateway --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: strut gateway <subcommand> --host <alias>"* ]]
}

@test "strut gateway deploy --help prints gateway usage" {
  local proj="$TEST_TMP/gw-deploy-help"
  _make_project "$proj"

  _run_in "$proj" gateway deploy --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: strut gateway <subcommand> --host <alias>"* ]]
}

@test "strut gateway <unknown-subcommand> --host fails with unknown-subcommand error" {
  local proj="$TEST_TMP/gw-unknown"
  _make_project "$proj"
  mkdir -p "$proj/stacks/gateway"

  _run_in "$proj" gateway bogus --host harbor

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown gateway subcommand: bogus"* ]]
}

# ── strut <host> provision | cert:renew | cert:status ────────────────────────

@test "strut <host> provision resolves the host from [hosts], not VPS_HOST fallback" {
  local proj="$TEST_TMP/host-provision"
  _make_project "$proj"
  mkdir -p "$proj/scripts"
  echo "echo hi" > "$proj/scripts/provision-harbor.sh"

  _run_in "$proj" harbor provision --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Target: ubuntu@1.2.3.4:22"* ]]
  [[ "$output" != *"Cannot resolve host"* ]]
}

@test "strut <host> cert:status resolves the host from [hosts]" {
  local proj="$TEST_TMP/host-cert-status"
  _make_project "$proj"

  _run_in "$proj" harbor cert:status --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cert Status: harbor"* ]]
  [[ "$output" != *"Cannot resolve host"* ]]
}

@test "strut <host> cert:renew resolves the host from [hosts]" {
  local proj="$TEST_TMP/host-cert-renew"
  _make_project "$proj"

  _run_in "$proj" harbor cert:renew --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Host: ubuntu@1.2.3.4:22"* ]]
  [[ "$output" != *"Cannot resolve host"* ]]
}

# ── Regression guard: ordinary stack dispatch is unaffected ──────────────────

@test "strut <realstack> deploy still dispatches to cmd_deploy normally" {
  local proj="$TEST_TMP/regular-stack"
  _make_project "$proj"
  mkdir -p "$proj/stacks/myapp"
  touch "$proj/stacks/myapp/docker-compose.yml"

  _run_in "$proj" myapp deploy --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" != *"Gateway Deploy"* ]]
  # cmd_deploy's first check is the env file — proves we reached it, not
  # a "stack not found" or "unknown command" dead end.
  [[ "$output" == *"Env file not found"* ]]
}
