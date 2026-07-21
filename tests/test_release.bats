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
  source "$CLI_ROOT/lib/hooks.sh"
  source "$CLI_ROOT/lib/deploy.sh"

  export CLI_ROOT="$TEST_TMP"
  export STRUT_HOME="$TEST_TMP"
  export DRY_RUN=false
  unset MIGRATION_FAILURE_MODE
  unset CMD_STACK_DIR
  mkdir -p "$TEST_TMP/stacks/test-stack/hooks"

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

@test "vps_release: dry-run prints the execution plan and makes no mutating SSH calls" {
  export DRY_RUN=true

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [[ "$output" == *"Execution plan for release"* ]]
  [[ "$output" == *"No changes made"* ]]

  # Dry-run uses run_cmd for display only, EXCEPT the git-clean preview,
  # which is deliberately real (git clean -nd is non-destructive) — assert
  # that's the only call recorded, not that zero calls happened.
  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"git clean -nd"* ]]
  [[ "$output" != *"reset --hard"* ]]
  [[ "$output" != *"migrate"* ]]
}

# ── Health-gated auto-rollback ────────────────────────────────────────────────

@test "vps_release: a failing final health check triggers rollback and returns non-zero" {
  export SSH_FAIL_PATTERN="health --env"

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"Health check failed"* ]]
  [[ "$output" == *"rolling back"* ]]
  [[ "$output" == *"Rolled back to the previous release"* ]]

  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"health --env test"* ]]
  [[ "$output" == *"rollback --env test"* ]]
}

@test "vps_release: still returns non-zero even when the rollback itself succeeds" {
  # A recovered rollback still means the requested release did not happen —
  # callers (CI, scripts) must see this as a failure, not a silent success.
  export SSH_FAIL_PATTERN="health --env"

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -ne 0 ]
}

@test "vps_release: --no-rollback (auto_rollback=false) skips rollback but still fails" {
  export SSH_FAIL_PATTERN="health --env"

  run vps_release "test-stack" "$TEST_TMP/.test.env" "" "false"
  [ "$status" -ne 0 ]
  [[ "$output" == *"auto-rollback disabled"* ]]

  run cat "$SSH_CALL_LOG"
  [[ "$output" != *"rollback --env"* ]]
}

@test "vps_release: warns but doesn't mask the original failure when rollback itself fails" {
  # stub_ssh_conditional only supports one glob pattern — need both the
  # health check AND the rollback call to fail here, so stub ssh() directly.
  SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
  : > "$SSH_CALL_LOG"
  export SSH_CALL_LOG
  ssh() {
    local remote_cmd
    remote_cmd="$(echo "${@: -1}" | tr '\n' ' ')"
    echo "$remote_cmd" >> "$SSH_CALL_LOG"
    case "$remote_cmd" in
      *"health --env"*|*"rollback --env"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f ssh

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"Automatic rollback also failed"* ]]
}

@test "vps_release: dry-run plan includes the rollback-on-failure step" {
  export DRY_RUN=true

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Roll back on health failure"* ]]
}

@test "vps_release: dry-run shows real untracked paths git clean -fd would remove" {
  export DRY_RUN=true
  SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
  : > "$SSH_CALL_LOG"
  export SSH_CALL_LOG
  ssh() {
    echo "$*" >> "$SSH_CALL_LOG"
    case "$*" in
      *"git clean -nd"*) echo "data/uploads/"; echo "orphan.tmp" ;;
    esac
    return 0
  }
  export -f ssh

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove the following untracked paths"* ]]
  [[ "$output" == *"data/uploads/"* ]]
  [[ "$output" == *"orphan.tmp"* ]]
}

@test "vps_release: a passing health check never invokes rollback" {
  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]

  run cat "$SSH_CALL_LOG"
  [[ "$output" != *"rollback --env"* ]]
}

# ── Release history recording ─────────────────────────────────────────────────

@test "vps_release: records a release history entry with outcome=success on the remote host" {
  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]

  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"history_record 'stacks/test-stack' release 'success'"* ]]
  [[ "$output" == *"env=test"* ]]
  [[ "$output" == *"duration_s:="* ]]
}

@test "vps_release: release history entry carries mode, remote-computed git_sha, and the controller's actor" {
  GITHUB_ACTOR=octocat run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]

  run cat "$SSH_CALL_LOG"
  # mode + actor are resolved on the controller and interpolated as literals.
  [[ "$output" == *"mode=standard"* ]]
  [[ "$output" == *"actor='octocat'"* ]]
  # git_sha and release_id are computed remotely — the captured text still
  # contains the (unexpanded) remote variable reference, proving they were
  # NOT resolved on the controller (see comment above the heredoc).
  [[ "$output" == *'git_sha=$_release_sha'* ]]
  [[ "$output" == *'release_id=$_release_id'* ]]
}

@test "vps_release: records outcome=failed when the final health check fails" {
  export SSH_FAIL_PATTERN="health --env"

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  # Health failure is fatal (auto-rollback) — history must still be
  # recorded before that exit, not skipped by it.
  [ "$status" -ne 0 ]

  run cat "$SSH_CALL_LOG"
  [[ "$output" == *"history_record 'stacks/test-stack' release 'failed'"* ]]
}

# ── --backup-first ─────────────────────────────────────────────────────────────

@test "vps_release: backup_first defaults to false — no backup call" {
  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]

  run cat "$SSH_CALL_LOG"
  [[ "$output" != *"backup all"* ]]
}

@test "vps_release: --backup-first (backup_first=true) backs up before updating the repo" {
  run vps_release "test-stack" "$TEST_TMP/.test.env" "" "true" "true"
  [ "$status" -eq 0 ]

  local line1
  line1=$(sed -n '1p' "$SSH_CALL_LOG")
  [[ "$line1" == *"backup all --env test"* ]]

  local line2
  line2=$(sed -n '2p' "$SSH_CALL_LOG")
  [[ "$line2" == *"vps_update_repo"* ]]
}

@test "vps_release: dry-run plan includes the backup step when --backup-first" {
  export DRY_RUN=true

  run vps_release "test-stack" "$TEST_TMP/.test.env" "" "true" "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Back up databases before release"* ]]
}

@test "vps_release: dry-run plan omits the backup step by default" {
  export DRY_RUN=true

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"Back up databases before release"* ]]
}

@test "vps_release: aborts the release when the pre-deploy backup fails" {
  export SSH_FAIL_PATTERN="backup all"

  run vps_release "test-stack" "$TEST_TMP/.test.env" "" "true" "true"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Pre-deploy backup failed"* ]]

  # Nothing past the backup step should have run.
  run cat "$SSH_CALL_LOG"
  [[ "$output" != *"vps_update_repo"* ]]
}

# ── pre_deploy_local / post_deploy_local (controller-side hooks, OSS-1086) ────

@test "vps_release: pre_deploy_local hook runs before repo sync and receives RELEASE_ENV_NAME" {
  cat > "$TEST_TMP/stacks/test-stack/hooks/pre_deploy_local.sh" <<'EOF'
#!/bin/bash
echo "pre_deploy_local ran env=$RELEASE_ENV_NAME"
EOF

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre_deploy_local ran env=test"* ]]

  # Must run before the repo is touched.
  [[ "$(echo "$output" | grep -n "pre_deploy_local ran" | cut -d: -f1)" -lt \
     "$(echo "$output" | grep -n "\[1/6\] Updating strut repository" | cut -d: -f1)" ]]
}

@test "vps_release: pre_deploy_local hook failure aborts the release before repo sync" {
  cat > "$TEST_TMP/stacks/test-stack/hooks/pre_deploy_local.sh" <<'EOF'
#!/bin/bash
echo "pre_deploy_local exploding" >&2
exit 7
EOF

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"pre_deploy_local hook failed"* ]]

  run cat "$SSH_CALL_LOG"
  [[ "$output" != *"vps_update_repo"* ]]
}

@test "vps_release: pre_deploy_local resolves from CMD_STACK_DIR when set, not CLI_ROOT/stacks/<stack>" {
  # A hook under the default CLI_ROOT/stacks/test-stack/hooks path that must
  # NOT run once CMD_STACK_DIR points elsewhere.
  cat > "$TEST_TMP/stacks/test-stack/hooks/pre_deploy_local.sh" <<'EOF'
#!/bin/bash
echo "wrong pre_deploy_local ran"
EOF

  local override_dir="$TEST_TMP/override-stack-dir"
  mkdir -p "$override_dir/hooks"
  cat > "$override_dir/hooks/pre_deploy_local.sh" <<'EOF'
#!/bin/bash
echo "override pre_deploy_local ran env=$RELEASE_ENV_NAME"
EOF

  export CMD_STACK_DIR="$override_dir"
  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"override pre_deploy_local ran env=test"* ]]
  [[ "$output" != *"wrong pre_deploy_local ran"* ]]
}

@test "vps_release: post_deploy_local hook runs after a successful release" {
  cat > "$TEST_TMP/stacks/test-stack/hooks/post_deploy_local.sh" <<'EOF'
#!/bin/bash
echo "post_deploy_local ran env=$RELEASE_ENV_NAME"
EOF

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"post_deploy_local ran env=test"* ]]
}

@test "vps_release: post_deploy_local hook failure warns but does not fail the release" {
  cat > "$TEST_TMP/stacks/test-stack/hooks/post_deploy_local.sh" <<'EOF'
#!/bin/bash
exit 1
EOF

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"post_deploy_local hook failed (continuing)"* ]]
}

@test "vps_release: post_deploy_local hook does not run when the final health check fails" {
  cat > "$TEST_TMP/stacks/test-stack/hooks/post_deploy_local.sh" <<'EOF'
#!/bin/bash
echo "post_deploy_local ran"
EOF
  export SSH_FAIL_PATTERN="health --env"

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -ne 0 ]
  [[ "$output" != *"post_deploy_local ran"* ]]
}

@test "vps_release: dry-run plan previews both local hooks without executing them" {
  cat > "$TEST_TMP/stacks/test-stack/hooks/pre_deploy_local.sh" <<'EOF'
#!/bin/bash
touch "$TEST_TMP/pre_marker"
EOF
  cat > "$TEST_TMP/stacks/test-stack/hooks/post_deploy_local.sh" <<'EOF'
#!/bin/bash
touch "$TEST_TMP/post_marker"
EOF
  export DRY_RUN=true

  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would run pre_deploy_local hook"* ]]
  [[ "$output" == *"Would run post_deploy_local hook"* ]]
  [ ! -f "$TEST_TMP/pre_marker" ]
  [ ! -f "$TEST_TMP/post_marker" ]
}

@test "vps_release: no-op when neither local hook is present" {
  run vps_release "test-stack" "$TEST_TMP/.test.env" ""
  [ "$status" -eq 0 ]
}
