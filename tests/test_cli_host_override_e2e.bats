#!/usr/bin/env bats
# ==================================================
# tests/test_cli_host_override_e2e.bats — --host override reaches remote
# dispatch end-to-end (strut#510)
# ==================================================
# Regression tests for strut#510: a stack mapped to one host in [stacks] but
# deployed with `--host <other-alias>` fell back to the static topology
# mapping for internal remote dispatch (deploy image-pull step, health fan-out)
# instead of the overridden host. These tests drive the real entrypoint (not
# just run_remote_strut/vps_release directly, which test_utils.bats and
# test_release.bats already cover at the function level) to prove the wiring
# holds end-to-end: `--host` must be the host actually dispatched to, and the
# topology-mapped default must never additionally fire.
#
# Run:  bats tests/test_cli_host_override_e2e.bats

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# _make_project <dir> — strut.conf mapping stack "buoy" to host "compass",
# with a second host "harbor" available for --host override.
_make_project() {
  local dir="$1"
  mkdir -p "$dir/stacks/buoy"
  touch "$dir/stacks/buoy/docker-compose.yml"
  cat > "$dir/strut.conf" <<'EOF'
REGISTRY_TYPE=none
DEFAULT_ORG=test
BANNER_TEXT=test

[hosts]
harbor = ubuntu@1.2.3.4:22
compass = ubuntu@5.6.7.8:22

[stacks]
buoy = compass
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

@test "strut <stack> health --host <alias> dispatches only to the override host, not the [stacks] default" {
  local proj="$TEST_TMP/health-override"
  _make_project "$proj"

  _run_in "$proj" buoy health --env prod --host harbor --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"ubuntu@1.2.3.4"* ]]
  [[ "$output" == *"--host harbor"* ]]
  [[ "$output" != *"5.6.7.8"* ]]
  [[ "$output" != *"--host compass"* ]]
}

@test "strut <stack> health with no --host dispatches to the [stacks] default" {
  local proj="$TEST_TMP/health-default"
  _make_project "$proj"

  _run_in "$proj" buoy health --env prod --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"ubuntu@5.6.7.8"* ]]
  [[ "$output" == *"--host compass"* ]]
  [[ "$output" != *"1.2.3.4"* ]]
}

@test "strut <stack> deploy --host <alias> --pull-only carries the override host into the remote command" {
  local proj="$TEST_TMP/deploy-override"
  _make_project "$proj"
  touch "$proj/.prod.env"

  _run_in "$proj" buoy deploy --env prod --host harbor --pull-only --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"ubuntu@1.2.3.4"* ]]
  [[ "$output" == *"--host harbor"* ]]
  [[ "$output" != *"5.6.7.8"* ]]
  [[ "$output" != *"--host compass"* ]]
}
