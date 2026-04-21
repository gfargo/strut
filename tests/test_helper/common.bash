#!/usr/bin/env bash
# ==================================================
# tests/test_helper/common.bash — Shared test setup
# ==================================================
# Source this in setup() for common helpers:
#   source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"

export CLI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Create a temp dir for test fixtures (cleaned up in teardown)
export TEST_TMP="$(mktemp -d)"

# Source utils.sh with fail() overridden to not exit the test runner
load_utils() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
}

# Source utils.sh + docker.sh
load_docker() {
  load_utils
  source "$CLI_ROOT/lib/docker.sh"
}

# Portable timeout wrapper — uses `timeout` on Linux, `gtimeout` on macOS
# (install via `brew install coreutils`), otherwise runs without a timeout.
#
# Usage: _timeout <seconds> <command> [args...]
_timeout() {
  if command -v timeout &>/dev/null; then
    timeout "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$@"
  else
    shift  # drop the duration
    "$@"
  fi
}

# Cleanup helper — call in teardown()
common_teardown() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}
