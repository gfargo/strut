#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_backup.bats — Smoke tests for cmd_backup dispatcher
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/hooks.sh"
  source "$CLI_ROOT/lib/notify.sh"
  source "$CLI_ROOT/lib/backup/engines.sh"
  source "$CLI_ROOT/lib/backup/cmd.sh"
  source "$CLI_ROOT/lib/cmd_backup.sh"

  # Stub everything cmd_backup dispatches to
  backup_verify_cmd() { echo "backup_verify_cmd $*"; }
  backup_verify_all_cmd() { echo "backup_verify_all_cmd $*"; }
  backup_list_cmd() { echo "backup_list_cmd $*"; }
  backup_health_cmd() { echo "backup_health_cmd $*"; }
  backup_schedule_set_cmd() { echo "backup_schedule_set_cmd $*"; }
  backup_schedule_list_cmd() { echo "backup_schedule_list_cmd $*"; }
  backup_schedule_install_defaults_cmd() { echo "backup_schedule_install_defaults_cmd $*"; }
  backup_retention_enforce_cmd() { echo "backup_retention_enforce_cmd $*"; }
  backup_retention_install_cron_cmd() { echo "backup_retention_install_cron_cmd $*"; }
  backup_storage_stats_cmd() { echo "backup_storage_stats_cmd $*"; }
  backup_check_missed_cmd() { echo "backup_check_missed_cmd $*"; }
  compare_neo4j_databases() { echo "compare_neo4j_databases $*"; }
  compare_postgres_databases() { echo "compare_postgres_databases $*"; }
  compare_neo4j_labels() { echo "compare_neo4j_labels $*"; }
  backup_postgres() { echo "backup_postgres $*"; }
  backup_neo4j() { echo "backup_neo4j $*"; }
  backup_mysql() { echo "backup_mysql $*"; }
  backup_sqlite() { echo "backup_sqlite $*"; }
  _backup_dir() { echo "/tmp/backups"; }
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  export_volume_paths() { return 0; }
  export -f backup_verify_cmd backup_verify_all_cmd backup_list_cmd backup_health_cmd \
            backup_schedule_set_cmd backup_schedule_list_cmd backup_schedule_install_defaults_cmd \
            backup_retention_enforce_cmd backup_retention_install_cron_cmd \
            backup_storage_stats_cmd backup_check_missed_cmd \
            compare_neo4j_databases compare_postgres_databases compare_neo4j_labels \
            backup_postgres backup_neo4j backup_mysql backup_sqlite \
            _backup_dir resolve_compose_cmd export_volume_paths

  mkdir -p "$TEST_TMP/stacks/test-stack"
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF

  export CLI_ROOT_SAVED="$CLI_ROOT"
  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="test"
  export CMD_SERVICES=""
  export CMD_JSON=""
  export DRY_RUN=false
}

teardown() {
  common_teardown
}

@test "_usage_backup: prints usage" {
  run _usage_backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"backup"* ]]
  [[ "$output" == *"postgres"* ]]
}

@test "cmd_backup: postgres routes to backup_postgres" {
  run cmd_backup postgres
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_postgres"* ]]
}

@test "cmd_backup: neo4j routes to backup_neo4j" {
  run cmd_backup neo4j
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_neo4j"* ]]
}

@test "cmd_backup: mysql routes to backup_mysql" {
  run cmd_backup mysql
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_mysql"* ]]
}

@test "cmd_backup: sqlite routes to backup_sqlite" {
  run cmd_backup sqlite
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_sqlite"* ]]
}

@test "cmd_backup: list routes to backup_list_cmd" {
  run cmd_backup list
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_list_cmd"* ]]
}

@test "cmd_backup: health routes to backup_health_cmd" {
  run cmd_backup health
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_health_cmd"* ]]
}

@test "cmd_backup: verify-all routes to backup_verify_all_cmd" {
  run cmd_backup verify-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_verify_all_cmd"* ]]
}

@test "cmd_backup: verify/verify-all/list/health load backup.conf (issue #389)" {
  local calls_log="$TEST_TMP/load_backup_conf_calls.log"
  load_backup_conf() { echo "$*" >> "$calls_log"; return 0; }
  export -f load_backup_conf

  run cmd_backup verify some-file.sql
  [ "$status" -eq 0 ]
  run cmd_backup verify-all
  [ "$status" -eq 0 ]
  run cmd_backup list
  [ "$status" -eq 0 ]
  run cmd_backup health
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$calls_log")" -eq 4 ]
}

@test "cmd_backup: verify without file fails" {
  run cmd_backup verify
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_backup: schedule list routes correctly" {
  run cmd_backup schedule list
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_schedule_list_cmd"* ]]
}

@test "cmd_backup: schedule with unknown subcommand fails" {
  run cmd_backup schedule bogus
  [[ "$output" == *"Unknown schedule"* ]]
}

@test "cmd_backup: retention enforce routes to backup_retention_enforce_cmd" {
  run cmd_backup retention enforce
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_retention_enforce_cmd"* ]]
}

@test "cmd_backup: retention with unknown subcommand fails" {
  run cmd_backup retention bogus
  [[ "$output" == *"Unknown retention"* ]]
}

@test "cmd_backup: storage routes to backup_storage_stats_cmd" {
  run cmd_backup storage
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_storage_stats_cmd"* ]]
}

@test "cmd_backup: unknown command fails with help" {
  run cmd_backup bogus-cmd
  [[ "$output" == *"Unknown backup command"* ]]
}

@test "cmd_backup: postgres dry-run shows plan" {
  export DRY_RUN=true
  run cmd_backup postgres
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_backup: all dry-run shows plan" {
  export DRY_RUN=true
  run cmd_backup all
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_backup: compare without envs fails" {
  run cmd_backup compare
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_backup: compare with two envs routes to compare funcs" {
  run cmd_backup compare env1 env2
  [ "$status" -eq 0 ]
  [[ "$output" == *"compare_neo4j_databases"* ]]
  [[ "$output" == *"compare_postgres_databases"* ]]
}

@test "cmd_backup: postgres failure triggers alert_backup_failure and aborts before offsite/notify" {
  backup_postgres() { echo "backup_postgres failed"; return 1; }
  export -f backup_postgres
  alert_backup_failure() { echo "alert_backup_failure $*"; }
  export -f alert_backup_failure
  offsite_sync_latest() { echo "offsite_sync_latest $*"; }
  export -f offsite_sync_latest
  notify_event() { echo "notify_event $*"; }
  export -f notify_event

  run cmd_backup postgres
  [ "$status" -ne 0 ]
  [[ "$output" == *"alert_backup_failure test-stack postgres"* ]]
  [[ "$output" != *"offsite_sync_latest"* ]]
  [[ "$output" != *"notify_event backup.success"* ]]
}

@test "cmd_backup: all continues after one engine failure and reports which failed" {
  # Simulate postgres fails, mysql succeeds
  backup_postgres() { return 1; }
  backup_mysql() { echo "mysql ok"; return 0; }
  export -f backup_postgres backup_mysql
  offsite_sync_all() { echo "offsite_sync_all $*"; return 0; }
  export -f offsite_sync_all
  notify_event() { echo "notify_event $*"; }
  export -f notify_event

  # Enable both engines
  BACKUP_ENGINES=(postgres mysql)
  backup_engine_enabled() { return 0; }
  backup_dump_fn() { echo "backup_$1"; }
  export -f backup_engine_enabled backup_dump_fn

  run cmd_backup all
  [ "$status" -ne 0 ]
  # MySQL should still have run despite postgres failure
  [[ "$output" == *"mysql ok"* ]]
  # Offsite sync should have been called
  [[ "$output" == *"offsite_sync_all"* ]]
  # Should report which engine(s) failed
  [[ "$output" == *"postgres"* ]]
}

@test "cmd_backup: all succeeds and calls offsite sync when all engines pass" {
  backup_postgres() { echo "pg ok"; return 0; }
  export -f backup_postgres
  offsite_sync_all() { echo "offsite_sync_all $*"; return 0; }
  export -f offsite_sync_all
  notify_event() { echo "notify_event $*"; }
  export -f notify_event

  BACKUP_ENGINES=(postgres)
  backup_engine_enabled() { return 0; }
  backup_dump_fn() { echo "backup_$1"; }
  export -f backup_engine_enabled backup_dump_fn

  run cmd_backup all
  [ "$status" -eq 0 ]
  [[ "$output" == *"pg ok"* ]]
  [[ "$output" == *"offsite_sync_all"* ]]
  [[ "$output" == *"notify_event backup.success"* ]]
}
