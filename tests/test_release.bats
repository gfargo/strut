#!/usr/bin/env bats
# ==================================================
# tests/test_release.bats — Unit tests for vps_release() (lib/deploy.sh)
# ==================================================
# OSS-399 / strut#253: vps_release had zero assertions on its internal
# control flow — tests/test_cmd_deploy.bats only proves cmd_release calls
# vps_release, with vps_release itself replaced by a one-line stub. This
# file sources lib/deploy.sh for real and stubs only the boundary (ssh via
# the shared stub_ssh_conditional helper, vps_update_repo, sleep) to
# exercise: SSH call ordering, MIGRATION_FAILURE_MODE=halt vs warn
# branching, --services propagation, dry-run plan output, and the
# non-fatal final health check.
#
# fail() is intentionally NOT overridden to a `return` stub here (unlike
# load_utils' default) — the halt-mode assertion relies on fail()'s real
# `exit 1` to actually abort vps_release mid-function. Under `run`, that
# exit only terminates the command-substitution subshell bats uses to
# capture $status/$output, so it's safe. See
# tests/test_backup_restore_safety.bats for the same reasoning.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/deploy.sh"

  export CLI_ROOT="$TEST_TMP"
  export STRUT_HOME="$TEST_TMP"
  export DRY_RUN=false
  unset MIGRATION_FAILURE_MODE

  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=example.com
EOF

  # No-fail-pattern by default — stub_ssh_conditional records every call to
  # $SSH_CALL_LOG and only fails calls matching SSH_FAIL_PATTERN (unset here).
  stub_ssh_conditional ""

  vps_update_repo() { echo "vps_update_repo $*" >> "$SSH_CALL_LOG"; return 0; }
  export -f vps_update_repo

  # The real function sleeps 10s at step 6 — no-op it so the test is fast.
  sleep() { :; }
  export -f sleep
}

teardown() {
  common_teardown
}

# ── Happy path: SSH call ordering ─────────────────────────────────────────────

@test "vps_release: happy path calls repo update, both migrations, pull, restart, health in order" {
  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]

  local line1 line2 line3 line4 line5 line6
  line1=$(sed -n '1p' "$SSH_CALL_LOG")
  line2=$(sed -n '2p' "$SSH_CALL_LOG")
  line3=$(sed -n '3p' "$SSH_CALL_LOG")
  line4=$(sed -n '4p' "$SSH_CALL_LOG")
  line5=$(sed -n '5p' "$SSH_CALL_LOG")
  line6=$(sed -n '6p' "$SSH_CALL_LOG")

  [[ "$line1" == *"vps_update_repo"* ]]
  [[ "$line2" == *"migrate postgres"* ]]
  [[ "$line3" == *"migrate neo4j"* ]]
  [[ "$line4" == *"deploy --env test"* ]]
  [[ "$line4" == *"--pull-only"* ]]
  [[ "$line5" == *"deploy --env test"* ]]
  [[ "$line5" != *"--pull-only"* ]]
  [[ "$line6" == *"health --env test"* ]]
}

# ── MIGRATION_FAILURE_MODE=halt ───────────────────────────────────────────────

@test "vps_release: MIGRATION_FAILURE_MODE=halt aborts before pull/restart when postgres migration fails" {
  export MIGRATION_FAILURE_MODE=halt
  export SSH_FAIL_PATTERN="migrate postgres"

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -ne 0 ]

  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"vps_update_repo"* ]]
  [[ "$output" == *"migrate postgres"* ]]
  [[ "$output" != *"deploy --env"* ]]
}

# ── MIGRATION_FAILURE_MODE=warn (default) ─────────────────────────────────────

@test "vps_release: default (warn) mode proceeds to pull/restart when postgres migration fails" {
  export SSH_FAIL_PATTERN="migrate postgres"

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Postgres migration failed"* ]]

  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"--pull-only"* ]]
  [[ "$output" == *"health --env test"* ]]
}

@test "vps_release: MIGRATION_FAILURE_MODE=halt aborts before pull/restart when neo4j migration fails" {
  export MIGRATION_FAILURE_MODE=halt
  export SSH_FAIL_PATTERN="migrate neo4j"

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -ne 0 ]

  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"migrate neo4j"* ]]
  [[ "$output" != *"deploy --env"* ]]
}

# ── --services profile propagation ────────────────────────────────────────────

@test "vps_release: propagates services profile to pull and restart SSH commands" {
  run vps_release "test-stack" "$TEST_TMP/.test.env" "core"
  [ "$status" -eq 0 ]

  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"deploy --env test --services core --pull-only"* ]]
  [[ "$output" == *"deploy --env test --services core"* ]]
}

# ── Dry run ────────────────────────────────────────────────────────────────────

@test "vps_release: dry-run prints the execution plan and makes no SSH mutation calls" {
  export DRY_RUN=true

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [[ "$output" == *"Execution plan for release"* ]]
  [[ "$output" == *"No changes made"* ]]

  # Dry-run uses run_cmd for display only — the recording ssh() stub must
  # never actually be invoked.
  [ ! -s "$SSH_CALL_LOG" ]
}

# ── Health check failure is non-fatal ──────────────────────────────────────────

@test "vps_release: a failing final health check warns but still returns 0" {
  export SSH_FAIL_PATTERN="health --env"

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Health check failed"* ]]

  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"health --env test"* ]]
}
