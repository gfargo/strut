#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_fleet_status.bats — Tests for `strut fleet status --json` (strut#399)
# ==================================================
# `_fleet_status --json` interpolated FLEET_DIRTY_COUNT raw and unescaped
# string fields into hand-built JSON: a blank/non-numeric dirty count (e.g.
# a truncated SSH stream) produced invalid JSON like "dirty":,, and any
# stray quote/backslash in a host alias or branch name broke the object.
#
# Run:  bats tests/test_cmd_fleet_status.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/topology.sh"
  source "$CLI_ROOT/lib/connection.sh"
  source "$CLI_ROOT/lib/fleet.sh"
  source "$CLI_ROOT/lib/cmd_fleet.sh"

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()
}

teardown() { common_teardown; }

@test "_fleet_status --json: normal host produces valid JSON with numeric dirty count" {
  _TOPO_HOSTS[compass]="gfargo@compass.local:22 ~/.ssh/id_rsa"

  fleet_git_status() {
    printf 'head_sha=abc1234\nbranch=main\nbehind=0\nahead=0\ndirty_count=2\n'
  }
  export -f fleet_git_status

  run _fleet_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(echo "$output" | jq -r '.hosts[0].dirty')" = "2" ]
}

@test "_fleet_status --json: blank dirty_count (truncated SSH stream) still produces valid JSON" {
  _TOPO_HOSTS[compass]="gfargo@compass.local:22 ~/.ssh/id_rsa"

  # dirty_count intentionally omitted — FLEET_DIRTY_COUNT stays unset/empty,
  # simulating a truncated remote stream.
  fleet_git_status() {
    printf 'head_sha=abc1234\nbranch=main\nbehind=0\nahead=0\n'
  }
  export -f fleet_git_status

  run _fleet_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(echo "$output" | jq -r '.hosts[0].dirty')" = "0" ]
}

@test "_fleet_status --json: non-numeric dirty_count is sanitized, not interpolated raw" {
  _TOPO_HOSTS[compass]="gfargo@compass.local:22 ~/.ssh/id_rsa"

  fleet_git_status() {
    printf 'head_sha=abc1234\nbranch=main\nbehind=0\nahead=0\ndirty_count=garbled\n'
  }
  export -f fleet_git_status

  run _fleet_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(echo "$output" | jq -r '.hosts[0].dirty')" = "0" ]
}

@test "_fleet_status --json: branch name with a double quote stays valid JSON" {
  _TOPO_HOSTS[compass]="gfargo@compass.local:22 ~/.ssh/id_rsa"

  fleet_git_status() {
    printf 'head_sha=abc1234\nbranch=feature/"weird"\nbehind=0\nahead=0\ndirty_count=0\n'
  }
  export -f fleet_git_status

  run _fleet_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [[ "$(echo "$output" | jq -r '.hosts[0].branch')" == *'"weird"'* ]]
}
