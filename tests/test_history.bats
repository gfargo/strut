#!/usr/bin/env bats
# ==================================================
# tests/test_history.bats — Tests for lib/history.sh
# ==================================================
# Run:  bats tests/test_history.bats
# Covers strut#333: deploy/release/rollback audit trail.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/history.sh"

  export STACK_DIR="$TEST_TMP/stacks/my-app"
  mkdir -p "$STACK_DIR"
}

teardown() { common_teardown; }

# ── history_record ────────────────────────────────────────────────────────────

@test "history_record: creates the history file on first write" {
  history_record "$STACK_DIR" "deploy" "success"
  [ -f "$STACK_DIR/.deploy-history.jsonl" ]
}

@test "history_record: appends one JSON line per call" {
  history_record "$STACK_DIR" "deploy" "success"
  history_record "$STACK_DIR" "rollback" "success"
  [ "$(wc -l < "$STACK_DIR/.deploy-history.jsonl" | tr -d ' ')" = "2" ]
}

@test "history_record: writes valid JSON with the standard fields" {
  history_record "$STACK_DIR" "release" "success"
  run cat "$STACK_DIR/.deploy-history.jsonl"
  [[ "$output" == *'"action":"release"'* ]]
  [[ "$output" == *'"outcome":"success"'* ]]
  [[ "$output" == *'"stack":"my-app"'* ]]
  [[ "$output" == *'"timestamp":"'* ]]
  [[ "$output" == *'"user":"'* ]]
}

@test "history_record: string extra fields (key=value) are JSON-escaped and quoted" {
  history_record "$STACK_DIR" "release" "success" 'env=prod'
  run cat "$STACK_DIR/.deploy-history.jsonl"
  [[ "$output" == *'"env":"prod"'* ]]
}

@test "history_record: raw extra fields (key:=value) are not quoted" {
  history_record "$STACK_DIR" "release" "success" 'duration_s:=45'
  run cat "$STACK_DIR/.deploy-history.jsonl"
  [[ "$output" == *'"duration_s":45'* ]]
  [[ "$output" != *'"duration_s":"45"'* ]]
}

@test "history_record: escapes quotes and backslashes in string field values" {
  history_record "$STACK_DIR" "release" "success" 'snapshot=weird"quote\path'
  run cat "$STACK_DIR/.deploy-history.jsonl"
  [[ "$output" == *'\"quote\\path'* ]]

  # And the line is still valid JSON if jq is available.
  if command -v jq &>/dev/null; then
    run jq -e . "$STACK_DIR/.deploy-history.jsonl"
    [ "$status" -eq 0 ]
  fi
}

@test "history_record: is best-effort — never fails the caller even if the dir can't be created" {
  run history_record "/nonexistent-root-dir-xyz/stacks/app" "deploy" "success"
  [ "$status" -eq 0 ]
}

@test "history_record: emits git_sha, release_id, and actor fields when passed as extras" {
  history_record "$STACK_DIR" "deploy" "success" "mode=standard" "git_sha=abc1234" "release_id=20260420-090000" "actor=ci-bot"
  run cat "$STACK_DIR/.deploy-history.jsonl"
  [[ "$output" == *'"mode":"standard"'* ]]
  [[ "$output" == *'"git_sha":"abc1234"'* ]]
  [[ "$output" == *'"release_id":"20260420-090000"'* ]]
  [[ "$output" == *'"actor":"ci-bot"'* ]]
}

@test "history_record: user field is CI-aware via history_actor (GITHUB_ACTOR wins over \$USER)" {
  GITHUB_ACTOR=octocat history_record "$STACK_DIR" "deploy" "success"
  run cat "$STACK_DIR/.deploy-history.jsonl"
  [[ "$output" == *'"user":"octocat"'* ]]
}

# ── history_git_sha / history_actor ───────────────────────────────────────────

@test "history_git_sha: returns a non-empty short SHA for this git repo" {
  run history_git_sha "$CLI_ROOT"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" != "unknown" ]]
}

@test "history_git_sha: best-effort — returns 'unknown' rather than failing on a non-git dir" {
  run history_git_sha "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "history_actor: falls back to \$USER when no CI vars are set" {
  unset GITHUB_ACTOR GITLAB_USER_LOGIN CI_COMMIT_AUTHOR
  USER=alice run history_actor
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "history_actor: prefers GITHUB_ACTOR over \$USER" {
  GITHUB_ACTOR=octocat USER=alice run history_actor
  [ "$status" -eq 0 ]
  [ "$output" = "octocat" ]
}

# ── history_list ───────────────────────────────────────────────────────────────

@test "history_list: reports no history when file doesn't exist" {
  run history_list "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No history recorded yet"* ]]
}

@test "history_list --json: emits an empty array when file doesn't exist" {
  run history_list "$STACK_DIR" --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "history_list: shows entries most-recent-first" {
  history_record "$STACK_DIR" "deploy" "success" "env=prod"
  sleep 1
  history_record "$STACK_DIR" "rollback" "success" "env=prod"

  run history_list "$STACK_DIR"
  [ "$status" -eq 0 ]
  # rollback (recorded second) should appear before deploy in the output
  local rollback_line deploy_line
  rollback_line=$(echo "$output" | grep -n "rollback" | head -1 | cut -d: -f1)
  deploy_line=$(echo "$output" | grep -n "deploy" | grep -v ACTION | head -1 | cut -d: -f1)
  [ "$rollback_line" -lt "$deploy_line" ]
}

@test "history_list --json: emits a valid JSON array of all entries" {
  history_record "$STACK_DIR" "deploy" "success"
  history_record "$STACK_DIR" "rollback" "failed"

  run history_list "$STACK_DIR" --json
  [ "$status" -eq 0 ]

  if command -v jq &>/dev/null; then
    echo "$output" > "$TEST_TMP/entries.json"
    run jq -e 'length == 2' "$TEST_TMP/entries.json"
    [ "$status" -eq 0 ]
  else
    [[ "$output" == "["*"]" ]]
  fi
}

@test "history_list: respects --limit" {
  history_record "$STACK_DIR" "deploy" "success"
  history_record "$STACK_DIR" "deploy" "success"
  history_record "$STACK_DIR" "deploy" "success"

  run history_list "$STACK_DIR" --limit 1
  [ "$status" -eq 0 ]
  # header row + exactly one data row (only when jq is present)
  if command -v jq &>/dev/null; then
    [ "$(echo "$output" | wc -l | tr -d ' ')" = "2" ]
  fi
}
