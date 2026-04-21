#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_db.bats — Smoke tests for db command handlers
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/cmd_db.sh"

  # Stubs
  postgres_apply_init_sql() { echo "postgres_apply_init_sql $*"; }
  postgres_verify_schema() { echo "postgres_verify_schema $*"; }
  restore_postgres() { echo "restore_postgres $*"; }
  restore_mysql() { echo "restore_mysql $*"; }
  restore_neo4j() { echo "restore_neo4j $*"; }
  restore_sqlite() { echo "restore_sqlite $*"; }
  db_pull() { echo "db_pull $*"; }
  db_push() { echo "db_push $*"; }
  resolve_compose_cmd() { echo "echo COMPOSE"; }
  validate_subcommand() {
    local value="$1"; shift
    for v in "$@"; do [ "$value" = "$v" ] && return 0; done
    echo "invalid subcommand: $value" >&2
    return 1
  }
  export -f postgres_apply_init_sql postgres_verify_schema \
            restore_postgres restore_mysql restore_neo4j restore_sqlite \
            db_pull db_push resolve_compose_cmd validate_subcommand

  mkdir -p "$TEST_TMP/stacks/test-stack"
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=
EOF

  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="test"
  export CMD_SERVICES=""
  export DRY_RUN=false
}

teardown() {
  common_teardown
}

@test "_usage_restore: prints usage" {
  run _usage_restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"restore"* ]]
}

@test "_usage_db_pull: prints usage" {
  run _usage_db_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"db:pull"* ]]
}

@test "_usage_db_push: prints usage" {
  run _usage_db_push
  [ "$status" -eq 0 ]
  [[ "$output" == *"db:push"* ]]
}

@test "cmd_db_schema: apply routes to postgres_apply_init_sql" {
  run cmd_db_schema apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgres_apply_init_sql"* ]]
}

@test "cmd_db_schema: verify routes to postgres_verify_schema" {
  run cmd_db_schema verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgres_verify_schema"* ]]
}

@test "cmd_db_schema: all runs apply + verify" {
  run cmd_db_schema all
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgres_apply_init_sql"* ]]
  [[ "$output" == *"postgres_verify_schema"* ]]
}

@test "cmd_db_schema: defaults to all when no arg" {
  run cmd_db_schema
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgres_apply_init_sql"* ]]
}

@test "cmd_restore: requires file arg" {
  run cmd_restore
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_restore: .sql routes to restore_postgres" {
  run cmd_restore /tmp/backup.sql
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore_postgres"* ]]
}

@test "cmd_restore: mysql-*.sql routes to restore_mysql" {
  run cmd_restore /tmp/mysql-20240101.sql
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore_mysql"* ]]
}

@test "cmd_restore: .dump routes to restore_neo4j" {
  run cmd_restore /tmp/backup.dump
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore_neo4j"* ]]
}

@test "cmd_restore: .db routes to restore_sqlite" {
  run cmd_restore /tmp/backup.db
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore_sqlite"* ]]
}

@test "cmd_restore: unknown extension fails" {
  run cmd_restore /tmp/backup.unknown
  [[ "$output" == *"Unknown backup file type"* ]]
}

@test "cmd_restore: dry-run shows plan" {
  export DRY_RUN=true
  run cmd_restore /tmp/backup.sql
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_restore: --target-env flag recognized" {
  run cmd_restore /tmp/backup.sql --target-env staging
  [ "$status" -eq 0 ]
  [[ "$output" == *"restore_postgres"* ]]
  [[ "$output" == *"staging"* ]]
}

@test "cmd_db_pull: routes to db_pull function" {
  run cmd_db_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"db_pull"* ]]
}

@test "cmd_db_pull: dry-run shows plan" {
  export DRY_RUN=true
  run cmd_db_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_db_pull: --download-only flag passes through" {
  run cmd_db_pull postgres --download-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"db_pull"* ]]
  [[ "$output" == *"true"* ]]
}

@test "cmd_db_push: routes to db_push function" {
  run cmd_db_push
  [ "$status" -eq 0 ]
  [[ "$output" == *"db_push"* ]]
}

@test "cmd_db_push: dry-run shows plan" {
  export DRY_RUN=true
  run cmd_db_push
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_db_push: --upload-only flag passes through" {
  run cmd_db_push postgres --upload-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"db_push"* ]]
  [[ "$output" == *"true"* ]]
}
