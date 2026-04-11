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
  unset DRY_RUN
}

# Helper: create a minimal stack for testing
_create_test_stack() {
  local stack="$1"
  local stack_dir="$CLI_ROOT/stacks/$stack"
  mkdir -p "$stack_dir"
  echo "version: '3'" > "$stack_dir/docker-compose.yml"
  # Create a minimal env file
  cat > "$CLI_ROOT/.test-dry.env" <<'EOF'
VPS_HOST=test-host
VPS_USER=ubuntu
EOF
}

# ── backup dry-run ────────────────────────────────────────────────────────────

@test "backup postgres: dry-run shows execution plan" {
  local stack="test-dry-backup-pg-$$"
  _create_test_stack "$stack"

  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_backup.sh"

  # Stub functions that would fail without Docker
  validate_env_file() { return 0; }
  export_volume_paths() { return 0; }
  resolve_compose_cmd() { echo "docker compose"; }

  run cmd_backup "$stack" "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env" "test-dry" "" "" "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"pg_dump"* ]]
  [[ "$output" == *"No changes made"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env"
}

@test "backup neo4j: dry-run mentions downtime" {
  local stack="test-dry-backup-neo-$$"
  _create_test_stack "$stack"

  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_backup.sh"

  validate_env_file() { return 0; }
  export_volume_paths() { return 0; }
  resolve_compose_cmd() { echo "docker compose"; }

  run cmd_backup "$stack" "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env" "test-dry" "" "" "neo4j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"Stop Neo4j"* ]]
  [[ "$output" == *"neo4j-admin dump"* ]]
  [[ "$output" == *"Restart Neo4j"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env"
}

@test "backup all: dry-run shows all enabled services" {
  local stack="test-dry-backup-all-$$"
  _create_test_stack "$stack"

  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_backup.sh"

  validate_env_file() { return 0; }
  export_volume_paths() { return 0; }
  resolve_compose_cmd() { echo "docker compose"; }

  run cmd_backup "$stack" "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env" "test-dry" "" "" "all"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"PostgreSQL"* ]]
  [[ "$output" == *"GDrive"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env"
}

@test "backup mysql: dry-run shows mysqldump" {
  local stack="test-dry-backup-mysql-$$"
  _create_test_stack "$stack"

  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_backup.sh"

  validate_env_file() { return 0; }
  export_volume_paths() { return 0; }
  resolve_compose_cmd() { echo "docker compose"; }

  run cmd_backup "$stack" "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env" "test-dry" "" "" "mysql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"mysqldump"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env"
}

@test "backup sqlite: dry-run shows copy" {
  local stack="test-dry-backup-sqlite-$$"
  _create_test_stack "$stack"

  source "$CLI_ROOT/lib/backup.sh"
  source "$CLI_ROOT/lib/cmd_backup.sh"

  validate_env_file() { return 0; }
  export_volume_paths() { return 0; }
  resolve_compose_cmd() { echo "docker compose"; }

  run cmd_backup "$stack" "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env" "test-dry" "" "" "sqlite"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"SQLite"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack" "$CLI_ROOT/.test-dry.env"
}

# ── domain dry-run ────────────────────────────────────────────────────────────

@test "domain: dry-run shows nginx execution plan" {
  source "$CLI_ROOT/lib/cmd_domain.sh"

  validate_env_file() { return 0; }
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  export VPS_HOST="test-host"
  export VPS_USER="ubuntu"
  export REVERSE_PROXY="nginx"

  run cmd_domain "my-stack" "$CLI_ROOT/.test-dry.env" "prod" "example.com" "admin@example.com"
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

  run cmd_domain "my-stack" "$CLI_ROOT/.test-dry.env" "prod" "example.com" "admin@example.com"
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

  run cmd_db_pull "my-stack" "$CLI_ROOT/.test-dry.env" "postgres"
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

  run cmd_db_pull "my-stack" "$CLI_ROOT/.test-dry.env" "postgres" "--download-only"
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

    local target="${targets[$((RANDOM % ${#targets[@]}))]}"

    cmd_backup "$stack" "$stack_dir" "$CLI_ROOT/.test-dry.env" "test" "" "" "$target" >/dev/null 2>&1

    # Property: no backup files should be created
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
