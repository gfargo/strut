#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_fleet.bats — Tests for `strut fleet history`
# ==================================================
# Run:  bats tests/test_cmd_fleet.bats
# Covers strut#333's fleet-wide aggregation: `strut fleet history`.
# `strut fleet status` (_fleet_status) has no pre-existing coverage either —
# out of scope here, this file is scoped to the new history subcommand.

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

  # Stub ssh — the aggregator cats a remote .deploy-history.jsonl file per
  # stack; tests configure per-host responses via SSH_HISTORY_<alias>.
  ssh() {
    local remote_cmd="${*: -1}"
    local host_arg="${*}"
    for alias in "${!_TOPO_HOSTS[@]}"; do
      local spec="${_TOPO_HOSTS[$alias]}"
      local host="${spec#*@}"; host="${host%%:*}"; host="${host%% *}"
      if [[ "$host_arg" == *"$host"* ]]; then
        local var="SSH_HISTORY_${alias//-/_}"
        printf '%s\n' "${!var:-}"
        return 0
      fi
    done
    return 1
  }
  export -f ssh
}

teardown() { common_teardown; }

@test "cmd_fleet history: reports when no stacks are mapped in topology" {
  run cmd_fleet history
  [ "$status" -eq 0 ]
  [[ "$output" == *"No stacks mapped"* ]]
}

@test "cmd_fleet history: aggregates entries from a single host/stack" {
  _TOPO_HOSTS[compass]="gfargo@compass.local:22 ~/.ssh/id_rsa"
  _TOPO_STACK_HOST[myapp]="compass"

  SSH_HISTORY_compass='{"timestamp":"2026-07-08T01:00:00Z","stack":"myapp","action":"release","user":"ubuntu","outcome":"success","env":"prod"}'
  export SSH_HISTORY_compass

  run cmd_fleet history
  [ "$status" -eq 0 ]
  [[ "$output" == *"compass"* ]]
  [[ "$output" == *"release"* ]]
  [[ "$output" == *"success"* ]]
}

@test "cmd_fleet history: aggregates across multiple hosts" {
  _TOPO_HOSTS[compass]="gfargo@compass.local:22 ~/.ssh/id_rsa"
  _TOPO_HOSTS[harbor]="ubuntu@harbor.local:22 ~/.ssh/id_rsa"
  _TOPO_STACK_HOST[app-a]="compass"
  _TOPO_STACK_HOST[app-b]="harbor"

  export SSH_HISTORY_compass='{"timestamp":"2026-07-08T01:00:00Z","stack":"app-a","action":"release","user":"ubuntu","outcome":"success"}'
  export SSH_HISTORY_harbor='{"timestamp":"2026-07-08T02:00:00Z","stack":"app-b","action":"rollback","user":"ubuntu","outcome":"success"}'

  run cmd_fleet history
  [ "$status" -eq 0 ]
  [[ "$output" == *"compass"* ]]
  [[ "$output" == *"harbor"* ]]
  [[ "$output" == *"release"* ]]
  [[ "$output" == *"rollback"* ]]
}

@test "cmd_fleet history: skips unreachable hosts without failing the whole command" {
  _TOPO_HOSTS[compass]="gfargo@compass.local:22 ~/.ssh/id_rsa"
  _TOPO_HOSTS[watch]="ubuntu@watch.local:22 ~/.ssh/id_rsa"
  _TOPO_STACK_HOST[app-a]="compass"
  _TOPO_STACK_HOST[app-b]="watch"

  export SSH_HISTORY_compass='{"timestamp":"2026-07-08T01:00:00Z","stack":"app-a","action":"release","user":"ubuntu","outcome":"success"}'
  unset SSH_HISTORY_watch

  run cmd_fleet history
  [ "$status" -eq 0 ]
  [[ "$output" == *"compass"* ]]
}

@test "cmd_fleet history --json: emits a JSON array" {
  _TOPO_HOSTS[compass]="gfargo@compass.local:22 ~/.ssh/id_rsa"
  _TOPO_STACK_HOST[myapp]="compass"

  export SSH_HISTORY_compass='{"timestamp":"2026-07-08T01:00:00Z","stack":"myapp","action":"release","user":"ubuntu","outcome":"success"}'

  run cmd_fleet history --json
  [ "$status" -eq 0 ]
  [[ "$output" == "["*"]" ]]
  if command -v jq &>/dev/null; then
    echo "$output" > "$TEST_TMP/out.json"
    run jq -e '. | length >= 1' "$TEST_TMP/out.json"
    [ "$status" -eq 0 ]
  fi
}

@test "cmd_fleet history --json: empty result is a valid empty array shape" {
  run cmd_fleet history --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"entries":[]'* ]]
}
