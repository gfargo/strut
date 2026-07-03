#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_doctor.bats — Tests for strut doctor command
# ==================================================
# Run:  bats tests/test_cmd_doctor.bats
# Covers: deploy-dir mismatch warning via fleet_git_status working_dir field

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/fleet.sh"
  source "$CLI_ROOT/lib/cmd_doctor.sh"

  # Reset doctor state
  _DOC_PASSED=0
  _DOC_WARNED=0
  _DOC_FAILED=0
  _DOC_JSON_RESULTS="[]"
  _DOC_JSON=false
  _DOC_FIX=false
}

teardown() {
  common_teardown
}

# ── deploy-dir mismatch via fleet_git_status output ──────────────────────────

# Helper: run the doctor parse block directly, simulating what _doc_check_vps
# does after fleet_git_status returns its key=value lines.
_parse_fleet_and_check() {
  local fleet_out="$1"
  local deploy_dir="$2"
  local env_name="$3"
  local branch="main"

  local f_behind="" f_ahead="" f_dirty="" f_head="" f_working_dir=""
  while IFS= read -r _fline; do
    case "${_fline%%=*}" in
      behind)      f_behind="${_fline#*=}" ;;
      ahead)       f_ahead="${_fline#*=}" ;;
      dirty_count) f_dirty="${_fline#*=}" ;;
      head_sha)    f_head="${_fline#*=}" ;;
      working_dir) f_working_dir="${_fline#*=}" ;;
    esac
  done <<< "$fleet_out"

  local _short_sha="${f_head:0:7}"
  if [ "${f_behind:-?}" = "0" ] && [ "${f_dirty:-0}" = "0" ]; then
    _doc_pass "VPS git ($env_name)" "in sync with origin/$branch (HEAD: $_short_sha)"
  else
    if [ "${f_behind:-?}" != "0" ] && [ "${f_behind:-?}" != "?" ] && [ -n "${f_behind:-}" ]; then
      _doc_warn "VPS git ($env_name)" \
        "$f_behind commit(s) behind origin/$branch — run: strut sync --env ${env_name#.}" \
        "strut sync --env ${env_name#.}"
    fi
    if [ "${f_dirty:-0}" != "0" ] && [ -n "${f_dirty:-}" ]; then
      _doc_warn "VPS dirty ($env_name)" \
        "$f_dirty locally modified file(s) on host" ""
    fi
  fi

  if [ -n "${f_working_dir:-}" ]; then
    local _expected_prefix="$deploy_dir/stacks/"
    if [[ "$f_working_dir" != "$_expected_prefix"* ]]; then
      _doc_warn "VPS deploy-dir ($env_name)" \
        "containers run from $f_working_dir, expected under ${_expected_prefix%/}" ""
    fi
  fi
}

@test "doctor: no deploy-dir warning when working_dir matches expected prefix" {
  local fleet_out="head_sha=abc1234
branch=main
behind=0
ahead=0
dirty_count=0
dirty_files=
working_dir=/home/ubuntu/strut/stacks/myapp"

  run _parse_fleet_and_check "$fleet_out" "/home/ubuntu/strut" "prod"
  [ "$status" -eq 0 ]
  [[ "$output" != *"deploy-dir"* ]]
}

@test "doctor: warns when container working_dir is under a different root" {
  local fleet_out="head_sha=abc1234
branch=main
behind=0
ahead=0
dirty_count=0
dirty_files=
working_dir=/opt/stacks/myapp"

  run _parse_fleet_and_check "$fleet_out" "/home/ubuntu/strut" "prod"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy-dir"* ]]
  [[ "$output" == *"/opt/stacks/myapp"* ]]
  [[ "$output" == *"/home/ubuntu/strut/stacks"* ]]
}

@test "doctor: no deploy-dir warning when working_dir is empty (no running containers)" {
  local fleet_out="head_sha=abc1234
branch=main
behind=0
ahead=0
dirty_count=0
dirty_files=
working_dir="

  run _parse_fleet_and_check "$fleet_out" "/home/ubuntu/strut" "staging"
  [ "$status" -eq 0 ]
  [[ "$output" != *"deploy-dir"* ]]
}

@test "doctor: working_dir mismatch warning is independent of behind/dirty state" {
  local fleet_out="head_sha=abc1234
branch=main
behind=5
ahead=0
dirty_count=2
dirty_files=file1|file2
working_dir=/opt/stacks/myapp"

  run _parse_fleet_and_check "$fleet_out" "/home/ubuntu/strut" "prod"
  [ "$status" -eq 0 ]
  # Should warn both about behind commits and deploy-dir mismatch
  [[ "$output" == *"behind"* ]]
  [[ "$output" == *"deploy-dir"* ]]
}

@test "doctor: no deploy-dir warning when working_dir is missing from fleet output" {
  local fleet_out="head_sha=abc1234
branch=main
behind=0
ahead=0
dirty_count=0
dirty_files="

  run _parse_fleet_and_check "$fleet_out" "/home/ubuntu/strut" "staging"
  [ "$status" -eq 0 ]
  [[ "$output" != *"deploy-dir"* ]]
}
