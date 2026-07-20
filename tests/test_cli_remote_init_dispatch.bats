#!/usr/bin/env bats
# ==================================================
# tests/test_cli_remote_init_dispatch.bats — remote:init dispatch reachability
# ==================================================
# Regression tests for OSS-829 / strut#378. Before the fix:
#   * `strut remote:init --host <h> --user <u>` had no top-level dispatch
#     case, so "remote:init" was parsed as STACK and died with
#     "Stack not found: 'remote:init'".
#   * `strut <stack> remote:init --host <h>` never re-injected --host into
#     the command args (only gateway/adopt did), and ran the raw host value
#     through topology_apply_host_override, which fail()s on any value that
#     isn't a [hosts] alias — but a brand-new host is by definition not one.
#
# These tests drive the real entrypoint with --repo/--dry-run so no network
# access or real git remote is required.
#
# Run:  bats tests/test_cli_remote_init_dispatch.bats

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_make_project() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/strut.conf" <<'EOF'
REGISTRY_TYPE=none
DEFAULT_ORG=test
BANNER_TEXT=test
EOF
}

_run_in() {
  local dir="$1"; shift
  run env -i \
    HOME="$TEST_TMP/home" \
    PATH="$PATH" \
    PWD="$dir" \
    bash -c "cd '$dir' && bash '$CLI' \"\$@\"" _ "$@"
}

# ── Top-level form: `strut remote:init --host <h> --user <u>` ────────────────

@test "strut remote:init --host is reachable at the top level (dry-run)" {
  local bare="$TEST_TMP/bare"
  mkdir -p "$bare"

  _run_in "$bare" remote:init --host 10.0.0.1 --user deploy --repo https://example.com/x/y.git --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" != *"Stack not found"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"deploy@10.0.0.1"* ]]
}

@test "strut remote:init dry-run does not attempt a real SSH connection" {
  local bare="$TEST_TMP/bare"
  mkdir -p "$bare"

  _run_in "$bare" remote:init --host 10.0.0.1 --user deploy --repo https://example.com/x/y.git --dry-run

  [ "$status" -eq 0 ]
  # Every step must be printed as a [DRY-RUN] plan line, not executed —
  # a live attempt would otherwise surface an ssh connection error/timeout.
  [[ "$output" != *"Connection timed out"* ]]
  [[ "$output" != *"Connection refused"* ]]
  [[ "$output" == *"[DRY-RUN] Test SSH connectivity"* ]]
}

@test "strut remote:init --help works at the top level" {
  local bare="$TEST_TMP/bare"
  mkdir -p "$bare"

  _run_in "$bare" remote:init --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--host"* ]]
}

@test "strut remote:init without --host fails with a connection-param error, not 'Stack not found'" {
  local bare="$TEST_TMP/bare"
  mkdir -p "$bare"

  _run_in "$bare" remote:init --repo https://example.com/x/y.git --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" != *"Stack not found"* ]]
  [[ "$output" == *"VPS_HOST"* ]] || [[ "$output" == *"--host"* ]]
}

# ── Stack-scoped form: `strut <stack> remote:init --host <raw-ip>` ───────────

@test "strut <stack> remote:init --host <raw-ip> reaches the handler without an 'Unknown host alias' error" {
  local proj="$TEST_TMP/stackproj"
  _make_project "$proj"
  mkdir -p "$proj/stacks/mystack"
  touch "$proj/stacks/mystack/docker-compose.yml"

  _run_in "$proj" mystack remote:init --host 203.0.113.7 --user deploy --repo https://example.com/x/y.git --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown host alias"* ]]
  [[ "$output" == *"203.0.113.7"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
}

# ── Regression: existing stack-scoped --env form is unaffected ───────────────

@test "strut <stack> remote:init --env still resolves without --host re-injection breaking it" {
  local proj="$TEST_TMP/envproj"
  _make_project "$proj"
  mkdir -p "$proj/stacks/mystack"
  touch "$proj/stacks/mystack/docker-compose.yml"

  # No env file present and no VPS_HOST — this should fail on the missing
  # connection info (not on stack/command dispatch).
  _run_in "$proj" mystack remote:init --env prod --repo https://example.com/x/y.git --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" != *"Stack not found"* ]]
  [[ "$output" != *"Unknown command"* ]]
  [[ "$output" == *"VPS_HOST"* ]] || [[ "$output" == *"--host"* ]]
}
