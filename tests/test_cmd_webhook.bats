#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_webhook.bats — Tests for lib/cmd_webhook.sh
# ==================================================
# Run:  bats tests/test_cmd_webhook.bats
# Covers: _all_stacks

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_webhook() {
  source "$CLI_ROOT/lib/cmd_webhook.sh"
}

# ── _all_stacks: trailing non-directory entry must not fail the function ─────
# Regression: ls sorts alphabetically, so a stray non-directory file sorting
# after all real stack dirs (e.g. a README, .DS_Store, editor swap file) made
# the loop's final `[ -d ... ]` test fail, which was the function's last
# executed command — returning exit 1 even though the stack list on stdout
# was correct. Under `set -euo pipefail`, the plain assignment
# `changed_stacks=$(_all_stacks "$cli_root")` in `_poll_cycle` would then
# abort the whole poll cycle via errexit.

@test "_all_stacks: returns 0 and lists only dirs when a non-dir file sorts last" {
  _load_webhook

  local root="$TEST_TMP/proj"
  mkdir -p "$root/stacks/alpha" "$root/stacks/beta"
  touch "$root/stacks/zzz-not-a-dir.txt"

  run _all_stacks "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alpha\nbeta')" ]
}

@test "_all_stacks: returns 0 and empty output when stacks dir is missing" {
  _load_webhook

  run _all_stacks "$TEST_TMP/nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_all_stacks: returns 0 and lists only dirs when stacks dir has no non-dir entries" {
  _load_webhook

  local root="$TEST_TMP/proj2"
  mkdir -p "$root/stacks/alpha" "$root/stacks/beta"

  run _all_stacks "$root"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alpha\nbeta')" ]
}
