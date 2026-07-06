#!/usr/bin/env bats
# ==================================================
# tests/test_tui.bats — Tests for lib/cmd_tui.sh
# ==================================================
# Run:  bats tests/test_tui.bats
# Covers: _tui_stacks, _tui_commands, _tui_envs, _tui_has_fzf, tui_main --help

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  source "$CLI_ROOT/lib/cmd_tui.sh"
}

teardown() { common_teardown; }

# ── _tui_has_fzf ─────────────────────────────────────────────────────────────

@test "_tui_has_fzf: returns 1 when STRUT_TUI_FORCE_SELECT=1" {
  STRUT_TUI_FORCE_SELECT=1
  run _tui_has_fzf
  [ "$status" -eq 1 ]
}

@test "_tui_has_fzf: returns based on fzf availability" {
  unset STRUT_TUI_FORCE_SELECT
  # This test just verifies the function doesn't crash
  # Result depends on whether fzf is installed on the test machine
  _tui_has_fzf || true
}

# ── _tui_stacks ──────────────────────────────────────────────────────────────

@test "_tui_stacks: lists stack directories" {
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks/my-app"
  mkdir -p "$TEST_TMP/stacks/api-server"
  mkdir -p "$TEST_TMP/stacks/shared"

  run _tui_stacks
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-app"* ]]
  [[ "$output" == *"api-server"* ]]
}

@test "_tui_stacks: excludes 'shared' directory" {
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks/my-app"
  mkdir -p "$TEST_TMP/stacks/shared"

  run _tui_stacks
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-app"* ]]
  [[ "$output" != *"shared"* ]]
}

@test "_tui_stacks: returns empty when no stacks directory" {
  export CLI_ROOT="$TEST_TMP"
  # No stacks/ directory at all

  run _tui_stacks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_tui_stacks: returns empty when stacks directory is empty" {
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks"

  run _tui_stacks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── _tui_commands ─────────────────────────────────────────────────────────────

@test "_tui_commands: lists expected commands" {
  export STRUT_HOME="$CLI_ROOT"
  run _tui_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"stop"* ]]
  [[ "$output" == *"health"* ]]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"logs"* ]]
  [[ "$output" == *"backup"* ]]
  [[ "$output" == *"drift"* ]]
  [[ "$output" == *"validate"* ]]
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"rollback"* ]]
}

@test "_tui_commands: includes release, update, diff, lock" {
  export STRUT_HOME="$CLI_ROOT"
  run _tui_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"release"* ]]
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"diff"* ]]
  [[ "$output" == *"lock"* ]]
}

@test "_tui_commands: includes commands added post-audit" {
  export STRUT_HOME="$CLI_ROOT"
  run _tui_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"migrate"* ]]
  [[ "$output" == *"restore"* ]]
  [[ "$output" == *"db:pull"* ]]
  [[ "$output" == *"secrets"* ]]
}

@test "_tui_commands: excludes host-scoped commands" {
  export STRUT_HOME="$CLI_ROOT"
  run _tui_commands
  [ "$status" -eq 0 ]
  # provision/cert:renew/cert:status take a host alias (strut.conf [hosts]),
  # not a stack — the TUI's stack picker could never offer a valid target.
  [[ "$output" != *"provision"* ]]
  [[ "$output" != *"cert:renew"* ]]
  [[ "$output" != *"cert:status"* ]]
}

@test "_tui_commands: excludes local/prod/staging/dev" {
  export STRUT_HOME="$CLI_ROOT"
  run _tui_commands
  [ "$status" -eq 0 ]
  # The command name IS the env selector for these and each expects its own
  # subcommand — incompatible with the generic stack->command->env flow.
  [[ "$output" != *"local"* ]]
  [[ "$output" != *"staging"* ]]
  [[ "$output" != *"dev"* ]]
}

@test "_tui_commands: excludes audit" {
  export STRUT_HOME="$CLI_ROOT"
  run _tui_commands
  [ "$status" -eq 0 ]
  [[ "$output" != *"audit"* ]]
}

# ── _tui_envs ────────────────────────────────────────────────────────────────

@test "_tui_envs: always includes (none) as first option" {
  export CLI_ROOT="$TEST_TMP"

  run _tui_envs ""
  [ "$status" -eq 0 ]
  # First line should be (none)
  local first_line
  first_line=$(echo "$output" | head -1)
  [ "$first_line" = "(none)" ]
}

@test "_tui_envs: discovers .prod.env files" {
  export CLI_ROOT="$TEST_TMP"
  touch "$TEST_TMP/.prod.env"
  touch "$TEST_TMP/.staging.env"

  run _tui_envs ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"prod"* ]]
  [[ "$output" == *"staging"* ]]
}

@test "_tui_envs: handles hyphenated env names" {
  export CLI_ROOT="$TEST_TMP"
  touch "$TEST_TMP/.my-app-prod.env"

  run _tui_envs ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-app-prod"* ]]
}

@test "_tui_envs: returns only (none) when no env files exist" {
  export CLI_ROOT="$TEST_TMP"

  run _tui_envs ""
  [ "$status" -eq 0 ]
  [ "$output" = "(none)" ]
}

@test "_tui_envs: discovers stack-level-only env file" {
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks/foo"
  touch "$TEST_TMP/stacks/foo/.staging.env"

  run _tui_envs "foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"staging"* ]]
}

@test "_tui_envs: does not leak one stack's env into another" {
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks/foo" "$TEST_TMP/stacks/bar"
  touch "$TEST_TMP/stacks/foo/.staging.env"

  run _tui_envs "bar"
  [ "$status" -eq 0 ]
  [[ "$output" != *"staging"* ]]
}

@test "_tui_envs: unions stack-level and project-level names without duplicates" {
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks/foo"
  touch "$TEST_TMP/stacks/foo/.prod.env"
  touch "$TEST_TMP/.prod.env"

  run _tui_envs "foo"
  [ "$status" -eq 0 ]
  local prod_count
  prod_count=$(echo "$output" | grep -c '^prod$')
  [ "$prod_count" -eq 1 ]
}

# ── tui_main ──────────────────────────────────────────────────────────────────

@test "tui_main: --help prints usage" {
  run tui_main --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--no-tui"* ]]
  [[ "$output" == *"--print"* ]]
}

@test "tui_main: warns when no stacks exist" {
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks"

  # _tui_pick will fail because there are no stacks
  run tui_main --print
  [ "$status" -ne 0 ]
  [[ "$output" == *"No stacks found"* ]] || [[ "$output" == *"WARN"* ]]
}

# ── _tui_pick ─────────────────────────────────────────────────────────────────

@test "_tui_pick: returns 1 when no items provided" {
  run _tui_pick "Choose"
  [ "$status" -eq 1 ]
}
