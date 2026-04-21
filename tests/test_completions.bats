#!/usr/bin/env bats
# ==================================================
# tests/test_completions.bats — Shell completion script generation
# ==================================================
# Run:  bats tests/test_completions.bats
# Covers: strut completions bash|zsh|fish output, syntax validity,
# content sanity (key tokens present), and error handling.

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLI_ROOT
  CLI="$CLI_ROOT/strut"
}

# ── Output sanity ────────────────────────────────────────────────────────────

@test "strut completions bash: emits completion script" {
  run bash "$CLI" completions bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"_strut_completions"* ]]
  [[ "$output" == *"complete -F _strut_completions strut"* ]]
}

@test "strut completions zsh: emits completion script" {
  run bash "$CLI" completions zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"#compdef strut"* ]]
  [[ "$output" == *"compdef _strut strut"* ]]
}

@test "strut completions fish: emits completion script" {
  run bash "$CLI" completions fish
  [ "$status" -eq 0 ]
  [[ "$output" == *"complete -c strut"* ]]
  [[ "$output" == *"__strut_stacks"* ]]
}

# ── Syntax validity ──────────────────────────────────────────────────────────

@test "bash completion script has valid bash syntax" {
  # Redirect to a temp file and bash -n parse-check it
  local tmp
  tmp=$(mktemp)
  bash "$CLI" completions bash > "$tmp"
  run bash -n "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

@test "zsh completion script has valid zsh syntax" {
  if ! command -v zsh >/dev/null 2>&1; then
    skip "zsh not installed"
  fi
  local tmp
  tmp=$(mktemp)
  bash "$CLI" completions zsh > "$tmp"
  run zsh -n "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

@test "fish completion script has valid fish syntax" {
  if ! command -v fish >/dev/null 2>&1; then
    skip "fish not installed"
  fi
  local tmp
  tmp=$(mktemp)
  bash "$CLI" completions fish > "$tmp"
  run fish -n "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

# ── Content coverage ─────────────────────────────────────────────────────────

@test "bash completion: includes core commands" {
  run bash "$CLI" completions bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"backup"* ]]
  [[ "$output" == *"init"* ]]
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"doctor"* ]]
}

@test "bash completion: includes service profiles for --services" {
  run bash "$CLI" completions bash
  [[ "$output" == *"messaging"* ]]
  [[ "$output" == *"full"* ]]
  [[ "$output" == *"gdrive"* ]]
}

@test "bash completion: handles --env flag with dynamic env names" {
  run bash "$CLI" completions bash
  [[ "$output" == *"_strut_envs"* ]]
  [[ "$output" == *".env"* ]]
}

@test "bash completion: handles --services flag" {
  run bash "$CLI" completions bash
  [[ "$output" == *"--services"* ]]
}

@test "zsh completion: includes core commands" {
  run bash "$CLI" completions zsh
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"backup"* ]]
  [[ "$output" == *"list"* ]]
}

@test "fish completion: includes core commands" {
  run bash "$CLI" completions fish
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"backup"* ]]
  [[ "$output" == *"list"* ]]
}

@test "bash completion: dynamic stack discovery function present" {
  run bash "$CLI" completions bash
  [[ "$output" == *"_strut_stacks"* ]]
  [[ "$output" == *"stacks"* ]]
}

# ── Error handling ───────────────────────────────────────────────────────────

@test "strut completions with no shell: shows usage and exits 1" {
  run bash "$CLI" completions
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: strut completions"* ]]
}

@test "strut completions --help: shows usage and exits 0" {
  run bash "$CLI" completions --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: strut completions"* ]]
}

@test "strut completions with unknown shell: fails" {
  run bash "$CLI" completions powershell
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown shell"* ]]
}

# ── Functional: source bash completion and verify complete() registered ──────

@test "bash completion: can be sourced and registers complete function" {
  local tmp
  tmp=$(mktemp)
  bash "$CLI" completions bash > "$tmp"
  # Source in a subshell with a compspec-capable bash; look for the complete binding
  run bash -c "source '$tmp' && complete -p strut"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_strut_completions"* ]]
  [[ "$output" == *"strut"* ]]
}

# ── init --completions ───────────────────────────────────────────────────────

@test "strut init --completions accepts the flag" {
  local test_tmp
  test_tmp=$(mktemp -d)
  cd "$test_tmp"
  # Force SHELL=bash so install targets ~/.bashrc.
  # Point HOME at a temp dir so we don't touch the user's real rc.
  local fake_home
  fake_home=$(mktemp -d)
  run env HOME="$fake_home" SHELL="/bin/bash" bash "$CLI" init --completions
  local st="$status"
  cd "$CLI_ROOT"
  rm -rf "$test_tmp" "$fake_home"
  [ "$st" -eq 0 ]
}
