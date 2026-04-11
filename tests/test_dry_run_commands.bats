#!/usr/bin/env bats
# ==================================================
# tests/test_dry_run_commands.bats — Tests for --dry-run across commands
# ==================================================
# Run:  bats tests/test_dry_run_commands.bats
# Covers: backup, domain, db:pull dry-run output

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }
  confirm() { return 0; }

  export DRY_RUN="true"
  export REVERSE_PROXY="nginx"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-dry-"*
  rm -rf "$TEST_TMP"
  unset DRY_RUN CMD_STACK CMD_STACK_DIR CMD_ENV_FILE CMD_ENV_NAME CMD_SERVICES CMD_JSON
}

_setup_backup_test() {
  local stack="$1"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  echo "version: '3'" > "$CLI_ROOT/stacks/$stack/docker-compose.yml"
  cat > "$CLI_ROOT/.test-dry.env" <<'EOF'
VPS_HOST=test-host
VPS_USER=ubuntu
EOF
  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_backup.sh"
  validate_env_file() { return 0; }
  export_volume_paths() { return 0; }
  resolve_compose_cmd() { echo "docker compose"; }
  export CMD_STACK="$stack"
  export CMD_STACK_DIR="$CLI_ROOT/stacks/$stack"
  export CMD_ENV_FILE="$CLI_ROOT/.test-dry.env"
  export CMD_ENV_NAME="test-dry"
  export CMD_SERVICES=""
  export CMD_JSON=""
}

# ── backup dry-run ────────────────────────────────────────────────────────────

@test "backup postgres: dry-run shows execution plan" {
  _setup_backup_test "test-dry-backup-pg-$$"
  run cmd_backup "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"pg_dump"* ]]
  [[ "$output" == *"No changes made"* ]]
  rm -rf "$CLI_ROOT/stacks/test-dry-backup-pg-$$" "$CLI_ROOT/.test-dry.env"
}

@test "backup neo4j: dry-run mentions downtime" {
  _setup_backup_test "test-dry-backup-neo-$$"
  run cmd_backup "neo4j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"Stop Neo4j"* ]]
  [[ "$output" == *"neo4j-admin dump"* ]]
  rm -rf "$CLI_ROOT/stacks/test-dry-backup-neo-$$" "$CLI_ROOT/.test-dry.env"
}

@test "backup all: dry-run shows all enabled services" {
  _setup_backup_test "test-dry-backup-all-$$"
  run cmd_backup "all"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"PostgreSQL"* ]]
  [[ "$output" == *"GDrive"* ]]
  rm -rf "$CLI_ROOT/stacks/test-dry-backup-all-$$" "$CLI_ROOT/.test-dry.env"
}

@test "backup mysql: dry-run shows mysqldump" {
  _setup_backup_test "test-dry-backup-mysql-$$"
  run cmd_backup "mysql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"mysqldump"* ]]
  rm -rf "$CLI_ROOT/stacks/test-dry-backup-mysql-$$" "$CLI_ROOT/.test-dry.env"
}

@test "backup sqlite: dry-run shows copy" {
  _setup_backup_test "test-dry-backup-sqlite-$$"
  run cmd_backup "sqlite"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"SQLite"* ]]
  rm -rf "$CLI_ROOT/stacks/test-dry-backup-sqlite-$$" "$CLI_ROOT/.test-dry.env"
}

# ── domain dry-run ────────────────────────────────────────────────────────────

@test "domain: dry-run shows nginx execution plan" {
  source "$CLI_ROOT/lib/cmd_domain.sh"
  validate_env_file() { return 0; }
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  export VPS_HOST="test-host"
  export VPS_USER="ubuntu"
  export REVERSE_PROXY="nginx"
  export CMD_STACK="my-stack"
  export CMD_STACK_DIR="$TEST_TMP"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="prod"
  export CMD_SERVICES=""
  export CMD_JSON=""

  run cmd_domain "example.com" "admin@example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"configure-domain.sh"* ]]
  [[ "$output" == *"nginx conf"* ]]
  [[ "$output" == *"No changes made"* ]]
  unset VPS_HOST VPS_USER
}

@test "domain: dry-run shows caddy execution plan" {
  source "$CLI_ROOT/lib/cmd_domain.sh"
  validate_env_file() { return 0; }
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  export VPS_HOST="test-host"
  export VPS_USER="ubuntu"
  export REVERSE_PROXY="caddy"
  export CMD_STACK="my-stack"
  export CMD_STACK_DIR="$TEST_TMP"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="prod"
  export CMD_SERVICES=""
  export CMD_JSON=""

  run cmd_domain "example.com" "admin@example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"Caddyfile"* ]]
  [[ "$output" == *"Reload Caddy"* ]]
  unset VPS_HOST VPS_USER REVERSE_PROXY
}

# ── db:pull dry-run ───────────────────────────────────────────────────────────

@test "db:pull: dry-run shows download plan" {
  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_db.sh"
  validate_env_file() { return 0; }
  validate_subcommand() { return 0; }
  export CMD_STACK="my-stack"
  export CMD_STACK_DIR="$TEST_TMP"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="prod"
  export CMD_SERVICES=""
  export CMD_JSON=""

  run cmd_db_pull "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"Download backup"* ]]
  [[ "$output" == *"Restore postgres"* ]]
  [[ "$output" == *"No changes made"* ]]
}

@test "db:pull: dry-run with --download-only skips restore" {
  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_db.sh"
  validate_env_file() { return 0; }
  validate_subcommand() { return 0; }
  export CMD_STACK="my-stack"
  export CMD_STACK_DIR="$TEST_TMP"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="prod"
  export CMD_SERVICES=""
  export CMD_JSON=""

  run cmd_db_pull "--download-only" "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"Download backup"* ]]
  [[ "$output" != *"Restore"* ]]
}

# ── Property: dry-run never creates files ─────────────────────────────────────

@test "Property: backup dry-run creates no files in backup directory (100 iterations)" {
  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_backup.sh"
  validate_env_file() { return 0; }
  export_volume_paths() { return 0; }
  resolve_compose_cmd() { echo "docker compose"; }

  local targets=("postgres" "neo4j" "mysql" "sqlite" "all")

  for i in $(seq 1 100); do
    local stack="test-dry-prop-$$-$i"
    local stack_dir="$CLI_ROOT/stacks/$stack"
    mkdir -p "$stack_dir"
    echo "version: '3'" > "$stack_dir/docker-compose.yml"

    export CMD_STACK="$stack"
    export CMD_STACK_DIR="$stack_dir"
    export CMD_ENV_FILE="$TEST_TMP/.test.env"
    export CMD_ENV_NAME="test"
    export CMD_SERVICES=""
    export CMD_JSON=""

    local target="${targets[$((RANDOM % ${#targets[@]}))]}"
    cmd_backup "$target" >/dev/null 2>&1

    local backup_count
    backup_count=$(find "$stack_dir" -name "*.sql" -o -name "*.dump" -o -name "*.db" -o -name "*.tar.gz" 2>/dev/null | wc -l)
    [ "$backup_count" -eq 0 ] || {
      echo "FAILED: dry-run created $backup_count backup files for target=$target"
      rm -rf "$stack_dir"
      return 1
    }

    rm -rf "$stack_dir"
  done
}
