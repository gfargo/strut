#!/usr/bin/env bats
# ==================================================
# tests/test_banner.bats — Property tests for banner and log prefix
# ==================================================
# Run:  bats tests/test_banner.bats
# Covers: print_banner, log prefix
# Feature: ch-deploy-modularization, Property 6

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_utils() {
  # Override fail to avoid exit in tests
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
}

# ── Helper: generate random alphanumeric string ──────────────────────────────

_rand_str() {
  local len="${1:-8}"
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$len" 2>/dev/null || true
}

# ── Property 6: Banner text from config appears in deploy output ─────────────
# Feature: ch-deploy-modularization, Property 6: Banner text from config appears in deploy output
# Validates: Requirements 4.1

@test "Property 6: Banner text from config appears in banner output (100 iterations)" {
  _load_utils

  for i in $(seq 1 100); do
    local brand="brand_$(_rand_str 6)"
    local subtitle="subtitle_$(_rand_str 6)"

    BANNER_TEXT="$brand"
    local output
    output=$(print_banner "$subtitle")

    # The banner output must contain the configured brand text
    [[ "$output" == *"$brand"* ]]
    # The banner output must contain the subtitle
    [[ "$output" == *"$subtitle"* ]]
  done
}

# ── Property 6 edge case: default banner text is "strut" ─────────────────────

@test "print_banner defaults to 'strut' when BANNER_TEXT is unset" {
  _load_utils
  unset BANNER_TEXT

  local output
  output=$(print_banner "Test Deploy")

  [[ "$output" == *"strut"* ]]
  [[ "$output" == *"Test Deploy"* ]]
}

# ── Property 6 edge case: empty BANNER_TEXT defaults to "strut" ──────────────

@test "print_banner defaults to 'strut' when BANNER_TEXT is empty" {
  _load_utils
  BANNER_TEXT=""

  local output
  output=$(print_banner "Test Deploy")

  # Empty string triggers bash default via ${BANNER_TEXT:-strut}
  [[ "$output" == *"strut"* ]]
}

# ── Log prefix uses [strut] ──────────────────────────────────────────────────

@test "log() prefix is [strut], not [ch-deploy]" {
  _load_utils

  local output
  output=$(log "hello world")

  [[ "$output" == *"[strut]"* ]]
  [[ "$output" == *"hello world"* ]]
  [[ "$output" != *"[ch-deploy]"* ]]
}

# ── Banner box structure is valid ─────────────────────────────────────────────

@test "print_banner produces valid box structure" {
  _load_utils
  BANNER_TEXT="my-project"

  local output
  output=$(print_banner "Release Deploy")

  # Should contain box drawing characters
  [[ "$output" == *"╔"* ]]
  [[ "$output" == *"╗"* ]]
  [[ "$output" == *"╚"* ]]
  [[ "$output" == *"╝"* ]]
  [[ "$output" == *"║"* ]]
}
