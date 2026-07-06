#!/usr/bin/env bats
# ==================================================
# tests/test_migrate_cutover.bats — Cutover ordering & rollback safety
# ==================================================
# Run:  bats tests/test_migrate_cutover.bats
# Covers: migrate_phase_cutover deploys and health-gates the new stack
#         before ever touching old containers, syncs artifacts + verifies
#         the strut binary first, invokes strut via ./strut (not bare
#         strut on PATH), rolls back the new stack on a failed health
#         check, and keeps one stack's failure from blocking others.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/migrate.sh"

  STACK="cutover-test-$$"
  mkdir -p "$CLI_ROOT/stacks/$STACK"
  echo "version: '3'" >"$CLI_ROOT/stacks/$STACK/docker-compose.yml"
  echo "FOO=bar" >"$CLI_ROOT/.$STACK-prod.env"

  MIGRATION_STACKS="$STACK"
  MIGRATE_AUTO_YES=true
  STRUT_YES=1

  CALL_LOG="$TEST_TMP/calls.log"
  : >"$CALL_LOG"

  # Defaults: strut present, artifacts sync, deploy + health both succeed
  STUB_STRUT_EXISTS=0
  STUB_SCP_RESULT=0
  STUB_DEPLOY_RESULT=0
  STUB_HEALTH_RESULT=0
  STUB_OLD_CONTAINERS="old-$STACK-container"

  ssh_exec() {
    local vps_user="$1" vps_host="$2" ssh_port="$3" ssh_key="$4"
    shift 4
    local command="$*"
    echo "SSH: $command" >>"$CALL_LOG"
    case "$command" in
      *"test -x"*)
        return "$STUB_STRUT_EXISTS"
        ;;
      *"mkdir -p"*)
        return 0
        ;;
      *"docker ps --format"*)
        echo "$STUB_OLD_CONTAINERS"
        return 0
        ;;
      *"docker stop "*)
        echo "STOP_OLD: $command" >>"$CALL_LOG"
        return 0
        ;;
      *"deploy --env"*)
        return "$STUB_DEPLOY_RESULT"
        ;;
      *"health --env"*)
        return "$STUB_HEALTH_RESULT"
        ;;
      *"stop --env"*)
        echo "STOP_NEW: $command" >>"$CALL_LOG"
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }

  build_scp_cmd() {
    echo "fake_scp"
  }

  fake_scp() {
    echo "SCP: $*" >>"$CALL_LOG"
    return "$STUB_SCP_RESULT"
  }

  confirm() {
    echo "CONFIRM: $1" >>"$CALL_LOG"
    return 0
  }

  vps_sudo_prefix() { echo ""; }
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/$STACK" 2>/dev/null
  rm -f "$CLI_ROOT/.$STACK-prod.env" 2>/dev/null
  rm -rf "$TEST_TMP"
  unset MIGRATION_STACKS MIGRATE_AUTO_YES STRUT_YES VPS_SUDO
}

@test "cutover: strut missing on VPS — stack skipped, old containers untouched" {
  STUB_STRUT_EXISTS=1

  run migrate_phase_cutover "host" "user" "" ""
  [ "$status" -eq 0 ]

  run grep -q "docker stop " "$CALL_LOG"
  [ "$status" -ne 0 ]

  run grep -q "deploy --env" "$CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "cutover: artifact sync fails — deploy never attempted, old containers untouched" {
  STUB_SCP_RESULT=1

  run migrate_phase_cutover "host" "user" "" ""
  [ "$status" -eq 0 ]

  run grep -q "deploy --env" "$CALL_LOG"
  [ "$status" -ne 0 ]

  run grep -q "docker stop " "$CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "cutover: deploy fails — old containers never stopped" {
  STUB_DEPLOY_RESULT=1

  run migrate_phase_cutover "host" "user" "" ""
  [ "$status" -eq 0 ]

  run grep -q "docker stop " "$CALL_LOG"
  [ "$status" -ne 0 ]

  run grep -q "health --env" "$CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "cutover: health check fails — new stack rolled back, old containers never stopped" {
  STUB_HEALTH_RESULT=1

  run migrate_phase_cutover "host" "user" "" ""
  [ "$status" -eq 0 ]

  run grep -q "STOP_NEW:" "$CALL_LOG"
  [ "$status" -eq 0 ]

  run grep -q "docker stop " "$CALL_LOG"
  [ "$status" -ne 0 ]
}

@test "cutover: deploy and health succeed — old containers stopped only after health check" {
  run migrate_phase_cutover "host" "user" "" ""
  [ "$status" -eq 0 ]

  run grep -q "STOP_OLD:" "$CALL_LOG"
  [ "$status" -eq 0 ]

  run grep -n "health --env" "$CALL_LOG"
  [ "$status" -eq 0 ]
  local health_line="${lines[0]%%:*}"

  run grep -n "STOP_OLD:" "$CALL_LOG"
  [ "$status" -eq 0 ]
  local stop_line="${lines[0]%%:*}"

  [ "$health_line" -lt "$stop_line" ]
}

@test "cutover: syncs artifacts (mkdir + scp) to the right remote path before deploy" {
  run migrate_phase_cutover "host" "user" "" ""
  [ "$status" -eq 0 ]

  run grep -q "mkdir -p /home/user/strut/stacks/$STACK" "$CALL_LOG"
  [ "$status" -eq 0 ]

  run grep -q "SCP:.*docker-compose.yml user@host:/home/user/strut/stacks/$STACK/docker-compose.yml" "$CALL_LOG"
  [ "$status" -eq 0 ]

  run grep -q "SCP:.*\.$STACK-prod\.env user@host:/home/user/strut/\.$STACK-prod\.env" "$CALL_LOG"
  [ "$status" -eq 0 ]

  run grep -n "mkdir -p" "$CALL_LOG"
  [ "$status" -eq 0 ]
  local mkdir_line="${lines[0]%%:*}"

  run grep -n "deploy --env" "$CALL_LOG"
  [ "$status" -eq 0 ]
  local deploy_line="${lines[0]%%:*}"

  [ "$mkdir_line" -lt "$deploy_line" ]
}

@test "cutover: invokes strut via ./strut, never bare strut on PATH" {
  run migrate_phase_cutover "host" "user" "" ""
  [ "$status" -eq 0 ]

  run grep -q "cd /home/user/strut && ./strut $STACK deploy --env $STACK-prod" "$CALL_LOG"
  [ "$status" -eq 0 ]

  run grep -q "cd /home/user/strut && ./strut $STACK health --env $STACK-prod" "$CALL_LOG"
  [ "$status" -eq 0 ]
}

@test "cutover: one stack's deploy failure does not block cutover of other stacks" {
  local stack2="cutover-test2-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack2"
  echo "version: '3'" >"$CLI_ROOT/stacks/$stack2/docker-compose.yml"
  echo "FOO=bar" >"$CLI_ROOT/.$stack2-prod.env"
  MIGRATION_STACKS="$STACK,$stack2"

  ssh_exec() {
    local vps_user="$1" vps_host="$2" ssh_port="$3" ssh_key="$4"
    shift 4
    local command="$*"
    echo "SSH: $command" >>"$CALL_LOG"
    case "$command" in
      *"test -x"*) return 0 ;;
      *"mkdir -p"*) return 0 ;;
      *"docker ps --format"*)
        echo ""
        return 0
        ;;
      *"docker stop "*)
        echo "STOP_OLD: $command" >>"$CALL_LOG"
        return 0
        ;;
      *"$STACK deploy"*) return 1 ;;
      *"deploy --env"*) return 0 ;;
      *"health --env"*) return 0 ;;
      *"stop --env"*)
        echo "STOP_NEW: $command" >>"$CALL_LOG"
        return 0
        ;;
      *) return 0 ;;
    esac
  }

  run migrate_phase_cutover "host" "user" "" ""
  [ "$status" -eq 0 ]

  run grep -q "$stack2 deploy" "$CALL_LOG"
  [ "$status" -eq 0 ]

  run grep -q "$stack2 health" "$CALL_LOG"
  [ "$status" -eq 0 ]

  rm -rf "$CLI_ROOT/stacks/$stack2"
  rm -f "$CLI_ROOT/.$stack2-prod.env"
}
