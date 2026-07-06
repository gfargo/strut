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

# ── Shared SSH/docker/confirm stubs ───────────────────────────────────────────
# Opt-in helpers — call from a test's setup() to install the stub. Not
# auto-applied, so existing per-file overrides keep working untouched.

# stub_ssh_recording [exit_code]
# Overrides ssh() to append the remote command (its last argument) to
# $TEST_TMP/ssh_calls.log and return $exit_code (default 0). Requires
# TEST_TMP to already be set (common.bash exports it above).
stub_ssh_recording() {
  local rc="${1:-0}"
  SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
  : > "$SSH_CALL_LOG"
  export SSH_CALL_LOG
  # shellcheck disable=SC2317
  ssh() {
    # Collapse the (often multi-line heredoc-style) remote command onto one
    # line so callers can reliably assert call ORDER with sed/grep -n.
    echo "${@: -1}" | tr '\n' ' ' >> "$SSH_CALL_LOG"
    echo >> "$SSH_CALL_LOG"
    return "${SSH_RECORDING_RC:-0}"
  }
  export SSH_RECORDING_RC="$rc"
  export -f ssh
}

# stub_ssh_conditional <pattern>
# Overrides ssh() to fail (return 1) only when the remote command (its last
# argument) contains <pattern>; succeeds otherwise. Also records every call
# to $TEST_TMP/ssh_calls.log like stub_ssh_recording.
stub_ssh_conditional() {
  SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
  : > "$SSH_CALL_LOG"
  export SSH_CALL_LOG
  export SSH_FAIL_PATTERN="$1"
  # shellcheck disable=SC2317
  ssh() {
    local remote_cmd
    remote_cmd="$(echo "${@: -1}" | tr '\n' ' ')"
    echo "$remote_cmd" >> "$SSH_CALL_LOG"
    [ -n "${SSH_FAIL_PATTERN:-}" ] && [[ "$remote_cmd" == *"$SSH_FAIL_PATTERN"* ]] && return 1
    return 0
  }
  export -f ssh
}

# stub_confirm_yes / stub_confirm_no
# Overrides confirm() so restore/destructive prompts don't block on stdin.
stub_confirm_yes() { confirm() { return 0; }; export -f confirm; }
stub_confirm_no()  { confirm() { return 1; }; export -f confirm; }

# stub_docker_recording
# Overrides docker() to append every invocation ("$*") to
# $TEST_TMP/docker_calls.log and return 0 — for tests that only need to
# assert docker was (or wasn't) invoked a certain way, without a real daemon.
stub_docker_recording() {
  DOCKER_CALL_LOG="$TEST_TMP/docker_calls.log"
  : > "$DOCKER_CALL_LOG"
  export DOCKER_CALL_LOG
  # shellcheck disable=SC2317
  docker() {
    echo "$*" >> "$DOCKER_CALL_LOG"
    return 0
  }
  export -f docker
}
