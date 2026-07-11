#!/usr/bin/env bats
# ==================================================
# tests/test_fleet.bats — Tests for lib/fleet.sh
# ==================================================
# Run:  bats tests/test_fleet.bats
# Covers: fleet_git_status_parse, fleet_git_status (ssh stubbed),
#         fleet_sync (ssh stubbed), fleet_working_dir_check

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/fleet.sh"

  # Stub ssh so nothing connects out
  ssh() { echo "ssh $*"; return 0; }
  export -f ssh
}

teardown() {
  common_teardown
}

# ── fleet_git_status_parse ────────────────────────────────────────────────────

@test "fleet_git_status_parse: extracts head_sha" {
  local out
  out=$(printf 'head_sha=abc123def456\nbranch=main\n' | fleet_git_status_parse)
  eval "$out"
  [ "$FLEET_HEAD_SHA" = "abc123def456" ]
}

@test "fleet_git_status_parse: extracts behind and ahead" {
  local out
  out=$(printf 'behind=5\nahead=0\n' | fleet_git_status_parse)
  eval "$out"
  [ "$FLEET_BEHIND" = "5" ]
  [ "$FLEET_AHEAD" = "0" ]
}

@test "fleet_git_status_parse: extracts dirty_count" {
  local out
  out=$(printf 'dirty_count=3\ndirty_files=M file1|?? file2|\n' | fleet_git_status_parse)
  eval "$out"
  [ "$FLEET_DIRTY_COUNT" = "3" ]
}

@test "fleet_git_status_parse: handles zero values" {
  local out
  out=$(printf 'behind=0\nahead=0\ndirty_count=0\ndirty_files=\n' | fleet_git_status_parse)
  eval "$out"
  [ "$FLEET_BEHIND" = "0" ]
  [ "$FLEET_DIRTY_COUNT" = "0" ]
}

@test "fleet_git_status_parse: handles ? for unknown behind/ahead" {
  local out
  out=$(printf 'behind=?\nahead=?\n' | fleet_git_status_parse)
  eval "$out"
  [ "$FLEET_BEHIND" = "?" ]
  [ "$FLEET_AHEAD" = "?" ]
}

@test "fleet_git_status_parse: extracts working_dir" {
  local out
  out=$(printf 'working_dir=/opt/stacks/myapp\n' | fleet_git_status_parse)
  eval "$out"
  [ "$FLEET_WORKING_DIR" = "/opt/stacks/myapp" ]
}

@test "fleet_git_status_parse: ignores unknown keys" {
  local out
  out=$(printf 'unknown_key=value\nbehind=2\n' | fleet_git_status_parse)
  eval "$out"
  [ "$FLEET_BEHIND" = "2" ]
  # FLEET_UNKNOWN_KEY should not be set
  [ -z "${FLEET_UNKNOWN_KEY:-}" ]
}

@test "fleet_git_status_parse: handles empty input" {
  local out
  out=$(printf '' | fleet_git_status_parse)
  [ -z "$out" ]
}

# ── fleet_git_status (ssh stubbed) ───────────────────────────────────────────

@test "fleet_git_status: invokes ssh" {
  run fleet_git_status ubuntu example.com 22 "" /home/ubuntu/strut main ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"example.com"* ]]
}

@test "fleet_git_status: passes deploy_dir to remote command" {
  run fleet_git_status ubuntu host.example 22 "" /opt/mystrut main ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"/opt/mystrut"* ]]
}

@test "fleet_git_status: includes branch in remote command" {
  run fleet_git_status ubuntu host.example 22 "" /home/ubuntu/strut develop ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"develop"* ]]
}

@test "fleet_git_status: uses SSH key when provided" {
  run fleet_git_status ubuntu host.example 22 /home/user/.ssh/id_rsa /home/ubuntu/strut main ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"id_rsa"* ]]
}

# ── fleet_sync (ssh stubbed) ──────────────────────────────────────────────────

@test "fleet_sync: --dry-run skips ssh call" {
  run fleet_sync ubuntu host.example 22 "" /home/ubuntu/strut main "" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  # The ssh stub would print "ssh ..." but dry-run should not invoke ssh
  [[ "$output" != *"ssh ubuntu@host.example"* ]]
}

@test "fleet_sync: without --dry-run invokes ssh" {
  run fleet_sync ubuntu host.example 22 "" /home/ubuntu/strut main ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"host.example"* ]]
}

@test "fleet_sync: passes deploy_dir to remote" {
  run fleet_sync ubuntu host.example 22 "" /opt/custom main ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"/opt/custom"* ]]
}

@test "fleet_sync: passes branch to remote" {
  run fleet_sync ubuntu host.example 22 "" /home/ubuntu/strut release/v2 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"release/v2"* ]]
}

@test "fleet_sync: --force-clean is passed to remote script" {
  run fleet_sync ubuntu host.example 22 "" /home/ubuntu/strut main "" --force-clean
  [ "$status" -eq 0 ]
  # The force_clean=true should appear in the heredoc sent to ssh
  [[ "$output" == *"force_clean"* ]] || [[ "$output" == *"true"* ]]
}

@test "fleet_sync: fails when deploy_dir is missing (ssh returns error)" {
  # Stub ssh to simulate missing deploy dir
  ssh() { echo "ERROR: /bad-dir not found on VPS" >&2; return 1; }
  export -f ssh

  run fleet_sync ubuntu host.example 22 "" /bad-dir main ""
  [ "$status" -ne 0 ]
}

@test "fleet_sync: remote script checks for .git before running git commands" {
  run fleet_sync ubuntu host.example 22 "" /opt/stacks/myapp main ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"/opt/stacks/myapp/.git"* ]]
  [[ "$output" == *"remote:init"* ]]
}

@test "fleet_sync: fails when deploy_dir exists but is not a git checkout" {
  # Stub ssh to simulate a real rsync-deployed (non-git) directory
  ssh() { echo "ERROR: /opt/stacks/myapp exists but is not a git checkout (no .git found)" >&2; return 1; }
  export -f ssh

  run fleet_sync ubuntu host.example 22 "" /opt/stacks/myapp main ""
  [ "$status" -ne 0 ]
}

# ── fleet_working_dir_check ───────────────────────────────────────────────────

@test "fleet_working_dir_check: returns 0 when dirs match" {
  run fleet_working_dir_check /home/ubuntu/strut myapp /home/ubuntu/strut/stacks/myapp
  [ "$status" -eq 0 ]
}

@test "fleet_working_dir_check: returns 1 when dirs differ" {
  run fleet_working_dir_check /home/ubuntu/strut myapp /opt/stacks/myapp
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected=/home/ubuntu/strut/stacks/myapp"* ]]
  [[ "$output" == *"actual=/opt/stacks/myapp"* ]]
}

@test "fleet_working_dir_check: returns 0 when container_working_dir is empty" {
  run fleet_working_dir_check /home/ubuntu/strut myapp ""
  [ "$status" -eq 0 ]
}

@test "fleet_working_dir_check: handles different deploy dirs" {
  run fleet_working_dir_check /opt/deploy myapp /opt/deploy/stacks/myapp
  [ "$status" -eq 0 ]
}

@test "fleet_working_dir_check: detects mismatch for alternate deploy convention" {
  run fleet_working_dir_check /opt/stacks myapp /home/ubuntu/strut/stacks/myapp
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected=/opt/stacks/stacks/myapp"* ]]
}
