#!/usr/bin/env bats
# ==================================================
# tests/test_backup_verify_alerts.bats — verify_backup alert wiring
# ==================================================
# Covers: verify_backup calling alert_verification_failure when the
# per-service verification helper fails.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/backup/engines.sh"
  source "$CLI_ROOT/lib/backup/verify.sh"

  alert_verification_failure() { echo "alert_verification_failure $*"; }
  export -f alert_verification_failure

  # Avoid touching real metadata files on disk — not under test here.
  create_backup_metadata() { :; }
  update_backup_metadata_verification() { :; }
  export -f create_backup_metadata update_backup_metadata_verification

  TEST_STACK="test-verify-alerts-$$"
  BACKUP_FILE="$TEST_TMP/postgres-20240101-000000.sql"
  echo "dummy" > "$BACKUP_FILE"
}

teardown() {
  common_teardown
}

@test "verify_backup: postgres verification failure triggers alert_verification_failure" {
  verify_postgres_backup() { return 1; }
  export -f verify_postgres_backup

  run verify_backup "$TEST_STACK" "$BACKUP_FILE" "echo COMPOSE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alert_verification_failure $TEST_STACK $BACKUP_FILE"* ]]
  [[ "$output" == *"postgres verification failed"* ]]
}

@test "verify_backup: postgres verification success does not call alert_verification_failure" {
  verify_postgres_backup() { echo '{"tables_verified":1,"row_count":0,"schema_valid":true,"duration_seconds":1}'; return 0; }
  export -f verify_postgres_backup

  run verify_backup "$TEST_STACK" "$BACKUP_FILE" "echo COMPOSE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"alert_verification_failure"* ]]
}
