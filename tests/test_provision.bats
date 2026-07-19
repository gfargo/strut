#!/usr/bin/env bats
# ==================================================
# tests/test_provision.bats — Tests for lib/cmd_provision.sh
# ==================================================
# Run:  bats tests/test_provision.bats
# Covers: _provision_find_script, _usage_provision, cmd_provision dry-run

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "BANNER: $*"; }
  run_cmd() { echo "RUN: $*"; }
  export -f fail ok warn log error print_banner run_cmd

  # Stub build_ssh_opts
  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  export -f build_ssh_opts

  source "$CLI_ROOT/lib/hooks.sh"
  source "$CLI_ROOT/lib/cmd_provision.sh"

  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
}

teardown() { common_teardown; }

# ── _usage_provision ──────────────────────────────────────────────────────────

@test "_usage_provision: prints usage information" {
  run _usage_provision
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--script"* ]]
  [[ "$output" == *"--verify"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "_usage_provision: includes examples" {
  run _usage_provision
  [ "$status" -eq 0 ]
  [[ "$output" == *"Examples:"* ]]
  [[ "$output" == *"provision"* ]]
}

# ── _provision_find_script ────────────────────────────────────────────────────

@test "_provision_find_script: finds scripts/provision-<host>.sh" {
  mkdir -p "$TEST_TMP/scripts"
  touch "$TEST_TMP/scripts/provision-harbor.sh"

  result=$(_provision_find_script "harbor")
  [ "$result" = "$TEST_TMP/scripts/provision-harbor.sh" ]
}

@test "_provision_find_script: finds infra/scripts/provision-<host>.sh" {
  mkdir -p "$TEST_TMP/infra/scripts"
  touch "$TEST_TMP/infra/scripts/provision-compass.sh"

  result=$(_provision_find_script "compass")
  [ "$result" = "$TEST_TMP/infra/scripts/provision-compass.sh" ]
}

@test "_provision_find_script: prefers scripts/ over infra/scripts/" {
  mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/infra/scripts"
  touch "$TEST_TMP/scripts/provision-node1.sh"
  touch "$TEST_TMP/infra/scripts/provision-node1.sh"

  result=$(_provision_find_script "node1")
  [ "$result" = "$TEST_TMP/scripts/provision-node1.sh" ]
}

@test "_provision_find_script: uses explicit path when provided" {
  mkdir -p "$TEST_TMP/custom"
  touch "$TEST_TMP/custom/my-script.sh"

  result=$(_provision_find_script "harbor" "$TEST_TMP/custom/my-script.sh")
  [ "$result" = "$TEST_TMP/custom/my-script.sh" ]
}

@test "_provision_find_script: returns 1 when explicit path doesn't exist" {
  run _provision_find_script "harbor" "/nonexistent/script.sh"
  [ "$status" -eq 1 ]
}

@test "_provision_find_script: returns 1 when no script found" {
  run _provision_find_script "unknown-host"
  [ "$status" -eq 1 ]
}

# ── cmd_provision dry-run ─────────────────────────────────────────────────────

@test "cmd_provision: dry-run shows execution plan" {
  mkdir -p "$TEST_TMP/scripts"
  echo "#!/bin/bash" > "$TEST_TMP/scripts/provision-harbor.sh"

  # Stub topology
  source "$CLI_ROOT/lib/topology.sh" 2>/dev/null || true
  topology_load() { :; }
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"
  export VPS_PORT="22"

  export CMD_STACK="harbor"
  export DRY_RUN=false

  run cmd_provision --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]
  [[ "$output" == *"SSH connectivity"* ]] || [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"provision"* ]]
}

@test "cmd_provision: dry-run with --verify shows verify mode" {
  mkdir -p "$TEST_TMP/scripts"
  echo "#!/bin/bash" > "$TEST_TMP/scripts/provision-harbor.sh"

  topology_load() { :; }
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias
  export VPS_HOST="10.0.0.1"
  export VPS_USER="deploy"

  export CMD_STACK="harbor"
  export DRY_RUN=false

  run cmd_provision --verify --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--verify"* ]]
}

@test "cmd_provision: fails when no host alias provided" {
  export CMD_STACK=""

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_provision --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Host alias required"* ]]
}

@test "cmd_provision: fails when no provision script found" {
  export CMD_STACK="unknown-host"

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  topology_load() { :; }
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias
  export VPS_HOST="10.0.0.1"

  run cmd_provision --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"No provision script found"* ]] || [[ "$output" == *"provision-unknown-host.sh"* ]]
}

@test "cmd_provision: fails when host cannot be resolved" {
  mkdir -p "$TEST_TMP/scripts"
  echo "#!/bin/bash" > "$TEST_TMP/scripts/provision-orphan.sh"

  export CMD_STACK="orphan"
  unset VPS_HOST

  topology_load() { :; }
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_provision --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot resolve host"* ]]
}

# ── _provision_find_scripts_dir / _provision_list_scripts ────────────────────

@test "_provision_find_scripts_dir: finds hosts/<host>/provision.d" {
  mkdir -p "$TEST_TMP/hosts/harbor/provision.d"

  result=$(_provision_find_scripts_dir "harbor")
  [ "$result" = "$TEST_TMP/hosts/harbor/provision.d" ]
}

@test "_provision_find_scripts_dir: returns 1 when no provision.d dir exists" {
  run _provision_find_scripts_dir "nohost"
  [ "$status" -eq 1 ]
}

@test "_provision_list_scripts: sorts scripts in lexical (C-locale) order" {
  mkdir -p "$TEST_TMP/scripts_dir"
  touch "$TEST_TMP/scripts_dir/30-c.sh" "$TEST_TMP/scripts_dir/10-a.sh" "$TEST_TMP/scripts_dir/20-b.sh"

  result=$(_provision_list_scripts "$TEST_TMP/scripts_dir")
  expected="$TEST_TMP/scripts_dir/10-a.sh
$TEST_TMP/scripts_dir/20-b.sh
$TEST_TMP/scripts_dir/30-c.sh"
  [ "$result" = "$expected" ]
}

# ── cmd_provision: directory model (hosts/<host>/provision.d/) ───────────────

# Scaffolds hosts/<host>/provision.d/{10-a,20-b,30-c}.sh plus host resolution
# and an scp() stub. Each test layers its own ssh() stub on top.
_provision_setup_dir_host() {
  local host="$1"
  mkdir -p "$TEST_TMP/hosts/$host/provision.d"
  echo "#!/bin/bash" > "$TEST_TMP/hosts/$host/provision.d/10-a.sh"
  echo "#!/bin/bash" > "$TEST_TMP/hosts/$host/provision.d/20-b.sh"
  echo "#!/bin/bash" > "$TEST_TMP/hosts/$host/provision.d/30-c.sh"

  topology_load() { :; }
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias
  export VPS_HOST="10.0.0.5"
  export VPS_USER="deploy"
  export VPS_PORT="22"

  export CMD_STACK="$host"
  export DRY_RUN=false

  : > "$TEST_TMP/ssh_calls.log"

  # shellcheck disable=SC2317
  scp() { echo "SCP: $*" >> "$TEST_TMP/scp_calls.log"; return 0; }
  export -f scp
}

@test "cmd_provision: dir model discovers and runs provision.d scripts in lexical order" {
  _provision_setup_dir_host "testhost"

  # shellcheck disable=SC2317
  ssh() {
    local remote_cmd="${*: -1}"
    echo "$remote_cmd" >> "$TEST_TMP/ssh_calls.log"
    case "$remote_cmd" in
      *"test -f"*".done"*) return 1 ;;  # no marker yet
      *) return 0 ;;
    esac
  }
  export -f ssh

  run cmd_provision
  [ "$status" -eq 0 ]

  local order
  order=$(grep "sudo bash" "$TEST_TMP/ssh_calls.log" | sed -E 's/.*(10-a|20-b|30-c).*/\1/')
  [ "$(echo "$order" | sed -n 1p)" = "10-a" ]
  [ "$(echo "$order" | sed -n 2p)" = "20-b" ]
  [ "$(echo "$order" | sed -n 3p)" = "30-c" ]
  [[ "$output" == *"3 run, 0 skipped"* ]]
}

@test "cmd_provision: dir model skips a script whose marker already exists" {
  _provision_setup_dir_host "testhost"

  # shellcheck disable=SC2317
  ssh() {
    local remote_cmd="${*: -1}"
    echo "$remote_cmd" >> "$TEST_TMP/ssh_calls.log"
    case "$remote_cmd" in
      *"20-b.done"*) return 0 ;;              # marker present -> skip
      *"test -f"*".done"*) return 1 ;;        # others absent -> run
      *) return 0 ;;
    esac
  }
  export -f ssh

  run cmd_provision
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping 20-b"* ]]
  ! grep -q "sudo bash /tmp/provision-testhost-20-b.sh" "$TEST_TMP/ssh_calls.log"
  grep -q "sudo bash /tmp/provision-testhost-10-a.sh" "$TEST_TMP/ssh_calls.log"
  grep -q "sudo bash /tmp/provision-testhost-30-c.sh" "$TEST_TMP/ssh_calls.log"
  [[ "$output" == *"2 run, 1 skipped"* ]]
}

@test "cmd_provision: --force re-runs provision.d scripts, ignoring markers" {
  _provision_setup_dir_host "testhost"

  # shellcheck disable=SC2317
  ssh() {
    local remote_cmd="${*: -1}"
    echo "$remote_cmd" >> "$TEST_TMP/ssh_calls.log"
    return 0  # every marker "present" -- --force must ignore this entirely
  }
  export -f ssh

  run cmd_provision --force
  [ "$status" -eq 0 ]
  ! grep -q "test -f" "$TEST_TMP/ssh_calls.log"
  grep -q "sudo bash /tmp/provision-testhost-10-a.sh" "$TEST_TMP/ssh_calls.log"
  grep -q "sudo bash /tmp/provision-testhost-20-b.sh" "$TEST_TMP/ssh_calls.log"
  grep -q "sudo bash /tmp/provision-testhost-30-c.sh" "$TEST_TMP/ssh_calls.log"
  [[ "$output" == *"3 run, 0 skipped"* ]]
}

@test "cmd_provision: dir model does not write a marker and aborts the batch on script failure" {
  _provision_setup_dir_host "testhost"

  # shellcheck disable=SC2317
  ssh() {
    local remote_cmd="${*: -1}"
    echo "$remote_cmd" >> "$TEST_TMP/ssh_calls.log"
    case "$remote_cmd" in
      *"test -f"*".done"*) return 1 ;;
      *"sudo bash /tmp/provision-testhost-10-a.sh"*) return 1 ;;  # first script fails
      *) return 0 ;;
    esac
  }
  export -f ssh

  run cmd_provision
  [ "$status" -ne 0 ]
  ! grep -q "10-a.done" "$TEST_TMP/ssh_calls.log"
  # batch stops after the failure -- 20-b/30-c never attempted
  ! grep -q "20-b" "$TEST_TMP/ssh_calls.log"
  ! grep -q "30-c" "$TEST_TMP/ssh_calls.log"
}

@test "cmd_provision: dir model writes the completion marker with sudo" {
  _provision_setup_dir_host "testhost"

  # shellcheck disable=SC2317
  ssh() {
    local remote_cmd="${*: -1}"
    echo "$remote_cmd" >> "$TEST_TMP/ssh_calls.log"
    case "$remote_cmd" in
      *"test -f"*".done"*) return 1 ;;  # no marker yet
      *) return 0 ;;
    esac
  }
  export -f ssh

  run cmd_provision
  [ "$status" -eq 0 ]
  grep -q "sudo sh -c .*10-a.done" "$TEST_TMP/ssh_calls.log"
  grep -q "sudo sh -c .*20-b.done" "$TEST_TMP/ssh_calls.log"
  grep -q "sudo sh -c .*30-c.done" "$TEST_TMP/ssh_calls.log"
}

@test "cmd_provision: dir model reports failure (not success) when the marker write fails" {
  _provision_setup_dir_host "testhost"

  # shellcheck disable=SC2317
  ssh() {
    local remote_cmd="${*: -1}"
    echo "$remote_cmd" >> "$TEST_TMP/ssh_calls.log"
    case "$remote_cmd" in
      *"test -f"*".done"*) return 1 ;;                 # no marker yet
      *"sudo sh -c"*"10-a.done"*) return 1 ;;           # marker write fails (e.g. permission denied)
      *) return 0 ;;
    esac
  }
  export -f ssh

  run cmd_provision
  [ "$status" -ne 0 ]
  [[ "$output" != *"3 run, 0 skipped"* ]]
  [[ "$output" == *"marker"* ]]
  # batch stops after the marker-write failure -- 20-b/30-c never attempted
  ! grep -q "20-b" "$TEST_TMP/ssh_calls.log"
  ! grep -q "30-c" "$TEST_TMP/ssh_calls.log"
}

@test "cmd_provision: dir model dry-run lists all scripts and makes no changes" {
  _provision_setup_dir_host "testhost"
  export DRY_RUN=true

  run cmd_provision --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"10-a"* ]]
  [[ "$output" == *"20-b"* ]]
  [[ "$output" == *"30-c"* ]]
  [[ "$output" == *"No changes made"* ]]
}

@test "cmd_provision: dir model warns when provision.d exists but has no scripts" {
  mkdir -p "$TEST_TMP/hosts/emptyhost/provision.d"

  topology_load() { :; }
  topology_is_host_alias() { return 1; }
  export -f topology_load topology_is_host_alias
  export VPS_HOST="10.0.0.5"
  export VPS_USER="deploy"
  export CMD_STACK="emptyhost"
  export DRY_RUN=false

  run cmd_provision
  [ "$status" -eq 0 ]
  [[ "$output" == *"No provision.d scripts found"* ]]
}

@test "cmd_provision: --script explicit overrides the directory model even when provision.d exists" {
  _provision_setup_dir_host "testhost"
  mkdir -p "$TEST_TMP/custom"
  echo "#!/bin/bash" > "$TEST_TMP/custom/legacy.sh"

  run cmd_provision --script "$TEST_TMP/custom/legacy.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy.sh"* ]]
}

@test "cmd_provision: dir model aborts the batch when pre_provision hook fails" {
  _provision_setup_dir_host "testhost"

  # shellcheck disable=SC2317
  fire_hook() {
    [ "$1" = "pre_provision" ] && return 1
    return 0
  }
  export -f fire_hook

  # shellcheck disable=SC2317
  ssh() {
    echo "${*: -1}" >> "$TEST_TMP/ssh_calls.log"
    return 0
  }
  export -f ssh

  run cmd_provision
  [ "$status" -ne 0 ]
  [[ "$output" == *"pre_provision hook failed"* ]]
  ! grep -q "sudo bash" "$TEST_TMP/ssh_calls.log"
}

@test "cmd_provision: dir model warns (but still succeeds) when post_provision hook fails" {
  _provision_setup_dir_host "testhost"

  # shellcheck disable=SC2317
  fire_hook() {
    [ "$1" = "post_provision" ] && return 1
    return 0
  }
  export -f fire_hook

  # shellcheck disable=SC2317
  ssh() {
    local remote_cmd="${*: -1}"
    echo "$remote_cmd" >> "$TEST_TMP/ssh_calls.log"
    case "$remote_cmd" in
      *"test -f"*".done"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f ssh

  run cmd_provision
  [ "$status" -eq 0 ]
  [[ "$output" == *"post_provision hook failed"* ]]
  grep -q "sudo bash /tmp/provision-testhost-30-c.sh" "$TEST_TMP/ssh_calls.log"
}
