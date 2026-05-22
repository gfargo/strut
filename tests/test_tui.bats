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

@test "_tui_commands: does not include audit or migrate" {
  run _tui_commands
  [ "$status" -eq 0 ]
  [[ "$output" != *"audit"* ]]
  [[ "$output" != *"migrate"* ]]
}

# ── _tui_envs ────────────────────────────────────────────────────────────────

@test "_tui_envs: always includes (none) as first option" {
  export CLI_ROOT="$TEST_TMP"

  run _tui_envs
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

  run _tui_envs
  [ "$status" -eq 0 ]
  [[ "$output" == *"prod"* ]]
  [[ "$output" == *"staging"* ]]
}

@test "_tui_envs: handles hyphenated env names" {
  export CLI_ROOT="$TEST_TMP"
  touch "$TEST_TMP/.my-app-prod.env"

  run _tui_envs
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-app-prod"* ]]
}

@test "_tui_envs: returns only (none) when no env files exist" {
  export CLI_ROOT="$TEST_TMP"

  run _tui_envs
  [ "$status" -eq 0 ]
  [ "$output" = "(none)" ]
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
