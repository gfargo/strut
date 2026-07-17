#!/usr/bin/env bats
# ==================================================
# tests/test_local_sync_db.bats — Tests for lib/local.sh's local_sync_db
# ==================================================
# Run:  bats tests/test_local_sync_db.bats
# Covers: issue #392 — declining one engine's restore confirm must only
# skip that engine, not the rest of the function (and the anonymize step
# that follows), and PII-related warnings around Neo4j anonymization.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  source "$CLI_ROOT/lib/local.sh"

  export STRUT_HOME="$CLI_ROOT"
  export CLI_ROOT="$TEST_TMP"
  export DRY_RUN=false

  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=vps.example.com
VPS_USER=deploy
EOF

  # Stubs: local stack is running, latest backups exist on the VPS, and
  # download/restore succeed unless a test overrides them.
  resolve_local_compose_cmd() { echo "fake_compose"; }
  fake_compose() {
    echo "$*" >> "$TEST_TMP/compose_calls.log"
    [[ "$*" == *"ps --services"* ]] && { echo "postgres"; return 0; }
    return 0
  }
  export -f fake_compose
  : > "$TEST_TMP/compose_calls.log"

  resolve_deploy_dir() { echo "/opt/app"; }
  _remote_backup_dir() { echo "/remote/backups"; }
  ssh() { echo "postgres-20260101-000000.sql"; }
  rsync() { touch "${!#}"; }

  backup_postgres() { return 0; }
  backup_neo4j() { return 0; }
  restore_postgres() { echo "RESTORE_POSTGRES_CALLED" >> "$TEST_TMP/restore_calls.log"; return 0; }
  restore_neo4j() { echo "RESTORE_NEO4J_CALLED" >> "$TEST_TMP/restore_calls.log"; return 0; }
  export -f restore_postgres restore_neo4j
  : > "$TEST_TMP/restore_calls.log"
}

teardown() { common_teardown; }

@test "local_sync_db: declining neo4j confirm still anonymizes an already-restored postgres (issue #392)" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  cat > "$TEST_TMP/stacks/$stack/anonymize.conf" <<'EOF'
users.email=fake_email
EOF

  # ssh needs to answer differently for postgres vs neo4j "latest backup" lookups
  ssh() {
    case "$*" in
      *postgres-\**) echo "postgres-20260101-000000.sql" ;;
      *neo4j-\**) echo "neo4j-20260101-000000.dump" ;;
      *) echo "" ;;
    esac
  }

  # Decline only the neo4j confirm (the second one asked)
  local confirm_call=0
  confirm() {
    confirm_call=$((confirm_call + 1))
    [ "$confirm_call" -eq 1 ] && return 0  # postgres: accept
    return 1                                # neo4j: decline
  }

  run local_sync_db "$stack" "prod" "all" --anonymize
  [ "$status" -eq 0 ]

  grep -q "RESTORE_POSTGRES_CALLED" "$TEST_TMP/restore_calls.log"
  ! grep -q "RESTORE_NEO4J_CALLED" "$TEST_TMP/restore_calls.log"
  # anon_apply_postgres runs against the real anonymize.sh — its psql exec
  # shows up in the compose call log.
  grep -q "psql" "$TEST_TMP/compose_calls.log"
  [[ "$output" == *"synced successfully"* ]]
}

@test "local_sync_db: declining postgres confirm does not prevent a subsequent neo4j restore attempt (issue #392)" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"

  ssh() {
    case "$*" in
      *postgres-\**) echo "postgres-20260101-000000.sql" ;;
      *neo4j-\**) echo "neo4j-20260101-000000.dump" ;;
      *) echo "" ;;
    esac
  }

  # Decline only the postgres confirm (the first one asked)
  local confirm_call=0
  confirm() {
    confirm_call=$((confirm_call + 1))
    [ "$confirm_call" -eq 1 ] && return 1  # postgres: decline
    return 0                                # neo4j: accept
  }

  run local_sync_db "$stack" "prod" "all"
  [ "$status" -eq 0 ]

  ! grep -q "RESTORE_POSTGRES_CALLED" "$TEST_TMP/restore_calls.log"
  grep -q "RESTORE_NEO4J_CALLED" "$TEST_TMP/restore_calls.log"
}

@test "local_sync_db: warns that Neo4j is not anonymized when it was restored with --anonymize (issue #392)" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  cat > "$TEST_TMP/stacks/$stack/anonymize.conf" <<'EOF'
users.email=fake_email
EOF

  ssh() {
    case "$*" in
      *postgres-\**) echo "" ;;
      *neo4j-\**) echo "neo4j-20260101-000000.dump" ;;
      *) echo "" ;;
    esac
  }
  confirm() { return 0; }

  run local_sync_db "$stack" "prod" "neo4j" --anonymize

  [ "$status" -eq 0 ]
  grep -q "RESTORE_NEO4J_CALLED" "$TEST_TMP/restore_calls.log"
  [[ "$output" == *"Neo4j has no anonymization support"* ]]
}
