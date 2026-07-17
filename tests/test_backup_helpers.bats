#!/usr/bin/env bats
# ==================================================
# tests/test_backup_helpers.bats — Tests for lib/backup.sh & lib/backup/retention.sh
# ==================================================
# Run:  bats tests/test_backup_helpers.bats
# Covers: _backup_dir, get_backup_list, calculate_backup_age

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  # Source utils with fail() overridden
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }

  # Source backup.sh (it sources submodules including retention.sh)
  source "$CLI_ROOT/lib/backup.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
  unset BACKUP_LOCAL_DIR
}

# ── _backup_dir ───────────────────────────────────────────────────────────────

@test "_backup_dir: returns default path when no config exists" {
  # Use a fake stack with no volume.conf or backup.conf
  unset BACKUP_LOCAL_DIR
  local result
  result=$(_backup_dir "nonexistent-stack")
  [[ "$result" == *"/stacks/nonexistent-stack/backups" ]]
}

@test "_backup_dir: respects BACKUP_LOCAL_DIR env var" {
  export BACKUP_LOCAL_DIR="/custom/backup/path"
  local result
  result=$(_backup_dir "any-stack")
  [ "$result" = "/custom/backup/path" ]
}

@test "_backup_dir: reads from volume.conf and backup.conf" {
  # Create a fake stack with volume.conf + backup.conf
  local stack_dir="$CLI_ROOT/stacks/test-backup-dir-$$"
  mkdir -p "$stack_dir"

  cat > "$stack_dir/volume.conf" <<'EOF'
BACKUP_PATH="/mnt/data/backups"
EOF
  cat > "$stack_dir/backup.conf" <<'EOF'
BACKUP_LOCAL_DIR="${BACKUP_PATH}/daily"
EOF

  unset BACKUP_LOCAL_DIR
  local result
  result=$(_backup_dir "test-backup-dir-$$")
  [ "$result" = "/mnt/data/backups/daily" ]

  # Cleanup
  rm -rf "$stack_dir"
}

@test "_backup_dir: aborts on missing include in volume.conf" {
  local stack_dir="$CLI_ROOT/stacks/test-backup-dir-missing-include-$$"
  mkdir -p "$stack_dir"

  cat > "$stack_dir/volume.conf" <<'EOF'
include = nonexistent.conf
EOF

  unset BACKUP_LOCAL_DIR
  run _backup_dir "test-backup-dir-missing-include-$$"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]

  rm -rf "$stack_dir"
}

# ── get_backup_list ───────────────────────────────────────────────────────────

@test "get_backup_list: lists postgres backups sorted newest first" {
  local stack="test-list-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  # Create test backup files with different timestamps
  touch "$backup_dir/postgres-20240101-120000.sql"
  sleep 0.1
  touch "$backup_dir/postgres-20240102-120000.sql"
  sleep 0.1
  touch "$backup_dir/postgres-20240103-120000.sql"

  run get_backup_list "$stack" "postgres"
  [ "$status" -eq 0 ]
  # Newest should be first
  local first_line
  first_line=$(echo "$output" | head -1)
  [[ "$first_line" == *"postgres-20240103-120000.sql" ]]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: lists neo4j backups with .dump extension" {
  local stack="test-list-neo4j-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  touch "$backup_dir/neo4j-20240101-120000.dump"
  touch "$backup_dir/neo4j-20240102-120000.dump"

  run get_backup_list "$stack" "neo4j"
  [ "$status" -eq 0 ]
  [[ "$output" == *"neo4j-20240101-120000.dump"* ]]
  [[ "$output" == *"neo4j-20240102-120000.dump"* ]]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: lists mysql backups with .sql extension" {
  local stack="test-list-mysql-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  touch "$backup_dir/mysql-20240101-120000.sql"

  run get_backup_list "$stack" "mysql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mysql-20240101-120000.sql"* ]]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: lists sqlite backups with .db extension" {
  local stack="test-list-sqlite-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  touch "$backup_dir/sqlite-20240101-120000.db"

  run get_backup_list "$stack" "sqlite"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sqlite-20240101-120000.db"* ]]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: fails on unknown service" {
  local stack="test-list-unknown-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  run get_backup_list "$stack" "redis"
  [ "$status" -eq 1 ]

  # Cleanup
  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "get_backup_list: fails when backup directory missing" {
  run get_backup_list "nonexistent-stack-$$" "postgres"
  [ "$status" -eq 1 ]
}

@test "get_backup_list: honors BACKUP_LOCAL_DIR for a custom, non-stacks/ path" {
  local custom_dir="$TEST_TMP/custom-backups-$$"
  mkdir -p "$custom_dir"
  touch "$custom_dir/postgres-20240101-120000.sql"

  export BACKUP_LOCAL_DIR="$custom_dir"
  run get_backup_list "any-stack" "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgres-20240101-120000.sql"* ]]
}

# ── calculate_backup_age ──────────────────────────────────────────────────────

@test "calculate_backup_age: returns 0 for file created today" {
  local test_file="$TEST_TMP/recent-backup.sql"
  touch "$test_file"

  run calculate_backup_age "$test_file"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "calculate_backup_age: fails for missing file" {
  run calculate_backup_age "$TEST_TMP/nonexistent.sql"
  [ "$status" -eq 1 ]
}

@test "calculate_backup_age: returns positive number for old file" {
  local test_file="$TEST_TMP/old-backup.sql"
  touch "$test_file"
  # Set modification time to 5 days ago
  touch -t "$(date -v-5d +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 days ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$test_file"

  run calculate_backup_age "$test_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]  # Allow 1-day rounding tolerance
}

# ── db_pull helpers (OSS-476 regression) ──────────────────────────────────────
# Guards against: _db_pull_find_and_download's log/rsync noise leaking into the
# captured stdout path (restore was silently broken for every engine), and
# _db_pull_sqlite restoring to production when the sourced env sets VPS_HOST.

@test "_db_pull_find_and_download: stdout is only the downloaded path, no log/rsync noise" {
  local remote_dir="/remote/backups"
  local local_dir="$TEST_TMP/download"
  mkdir -p "$local_dir"

  # Mocks: ssh emits the remote filename found by `ls -t | head -1`;
  # rsync "downloads" by touching the local destination (last positional arg).
  ssh() { echo "sqlite-20260101-000000.db"; }
  rsync() { touch "${!#}"; }

  local local_file
  local_file=$(_db_pull_find_and_download "-o Test=1" "vpsuser" "vpshost" \
    "$remote_dir" "$local_dir" "sqlite-*.db" "")

  [ "$local_file" = "$local_dir/sqlite-20260101-000000.db" ]
  [ -f "$local_file" ]
  [[ "$local_file" != *"[strut]"* ]]
  [[ "$local_file" != *"Downloading"* ]]
}

@test "_db_pull_postgres: a --file for a different engine is ignored, falls back to latest postgres backup (issue #387)" {
  local remote_dir="/remote/backups"
  local local_dir="$TEST_TMP/pg-download"
  mkdir -p "$local_dir"

  # ssh only responds to the postgres glob — if _db_pull_postgres passed the
  # mismatched mysql-*.sql filename straight through as the specific file, no
  # `ls -t` call would happen and rsync would try to fetch that literal name.
  ssh() {
    case "$*" in
      *"postgres-*.sql"*) echo "postgres-20260101-000000.sql" ;;
      *) echo "SHOULD NOT BE CALLED WITH MISMATCHED FILE" ;;
    esac
  }
  rsync() { touch "${!#}"; }

  DRY_RUN=false run _db_pull_postgres "-o Test=1" "vpsuser" "vpshost" \
    "$remote_dir" "$local_dir" "fake_compose" "true" "mysql-20260101-000000.sql"

  [ "$status" -eq 0 ]
  [ -f "$local_dir/postgres-20260101-000000.sql" ]
  [ ! -f "$local_dir/mysql-20260101-000000.sql" ]
}

@test "_db_pull_sqlite: restores locally even when ambient VPS_HOST is set (no prod overwrite)" {
  local remote_dir="/remote/backups"
  local backup_dir="$TEST_TMP/download"
  mkdir -p "$backup_dir"

  ssh() { echo "sqlite-20260101-000000.db"; }
  rsync() { touch "${!#}"; }
  confirm() { return 0; }
  restore_sqlite() { echo "restore_sqlite called with VPS_HOST=[${VPS_HOST:-}] args=$*"; }

  # Simulates db_pull sourcing a remote env file, which sets VPS_HOST.
  export VPS_HOST="prod.example.com"
  # _db_pull_sqlite references $stack (not one of its own params) via the
  # caller's (db_pull's) local scope — set it here to match that contract.
  local stack="test-stack"

  local output
  output=$(_db_pull_sqlite "-o Test=1" "vpsuser" "vpshost" \
    "$remote_dir" "$backup_dir" "echo COMPOSE" "false" "sqlite" "" 2>&1)

  [[ "$output" == *"restore_sqlite called with VPS_HOST=[]"* ]]
}

# ── BACKUP_NEO4J_SERVICE / BACKUP_MYSQL_SERVICE (OSS-406 regression) ──────────
# Guards against the bug this ticket was filed to prevent recurring: engines
# beyond postgres silently ignoring their configured service/container name
# and falling back to a hardcoded default (or, for mysql, an org-specific
# literal container name that had leaked into the engine).

@test "backup_neo4j: resolves the container via configured BACKUP_NEO4J_SERVICE, not the hardcoded 'neo4j' name" {
  local stack="test-neo4j-svc-$$"
  local stack_dir="$CLI_ROOT/stacks/$stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/backup.conf" <<'EOF'
BACKUP_NEO4J_SERVICE="graphdb"
EOF

  export BACKUP_LOCAL_DIR="$TEST_TMP/neo4j-backups"
  mkdir -p "$BACKUP_LOCAL_DIR"

  local expected_container="${stack}-graphdb-1"

  # Minimal docker stub: only responds to `docker ps --filter name=graphdb`.
  # If backup_neo4j fell back to the hardcoded "neo4j" filter, this stub
  # would never find a container and the function would fail immediately —
  # exactly the failure mode this test guards against.
  docker() {
    case "$1" in
      ps)
        local filter=""
        local a
        for a in "$@"; do
          case "$a" in name=*) filter="${a#name=}" ;; esac
        done
        [ "$filter" = "graphdb" ] && echo "$expected_container"
        ;;
      stop|start) return 0 ;;
      inspect)
        case "$*" in
          *'Config.Image'*) echo "neo4j:5.19-community" ;;
          *'State.Status'*) echo "exited" ;;
          *'Destination "/data"'*) echo "/fake/data" ;;
          *'Destination "/var/lib/neo4j/import"'*) echo "/fake/import" ;;
        esac
        ;;
      run) echo "Dump completed successfully" ;;
      cp) touch "${!#}" ;;
      exec) return 0 ;;
      *) return 0 ;;
    esac
  }
  export -f docker

  vps_sudo_prefix() { echo ""; }
  stub_compose() {
    case "$*" in
      *"ps "*) echo '"Health":"healthy"' ;;
      *) return 0 ;;
    esac
  }

  load_backup_conf "$stack" "$stack_dir"
  run backup_neo4j "$stack" "stub_compose"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using container: $expected_container"* ]]

  rm -rf "$stack_dir"
}

@test "backup_mysql: honors BACKUP_MYSQL_SERVICE for the compose exec target, not a hardcoded service name" {
  local stack="test-mysql-svc-$$"
  local stack_dir="$CLI_ROOT/stacks/$stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/backup.conf" <<'EOF'
BACKUP_MYSQL_SERVICE="customsvc"
EOF

  export BACKUP_LOCAL_DIR="$TEST_TMP/mysql-backups"
  mkdir -p "$BACKUP_LOCAL_DIR"
  export MYSQL_DATABASE="appdb"
  unset MYSQL_CONTAINER_NAME MYSQL_ROOT_PASSWORD MYSQL_USER MYSQL_PASSWORD

  vps_sudo_prefix() { echo ""; }

  # Only responds when exec'd against the configured service name — if
  # backup_mysql fell back to a hardcoded container/service, this stub
  # returns nonzero and the backup fails.
  fake_compose() {
    case "$*" in
      *"exec -T -e MYSQL_PWD customsvc"*) echo "-- mysqldump output --"; return 0 ;;
      *) return 1 ;;
    esac
  }

  load_backup_conf "$stack" "$stack_dir"
  run backup_mysql "$stack" fake_compose
  [ "$status" -eq 0 ]

  rm -rf "$stack_dir"
}

@test "_db_push_mysql: remote restore never puts the MySQL password in ssh argv (issue #390)" {
  local stack="test-mysql-push-$$"
  local backup_dir="$TEST_TMP/mysql-push-backups"
  mkdir -p "$backup_dir"
  echo "-- dump --" > "$backup_dir/mysql-20260101-000000.sql"

  export MYSQL_ROOT_PASSWORD="s3cret-push-password"
  export MYSQL_DATABASE="appdb"
  export STRUT_YES=1

  _db_push_upload() { return 0; }

  local ssh_log="$TEST_TMP/ssh_argv.log"
  local ssh_stdin_log="$TEST_TMP/ssh_stdin.log"
  ssh() {
    printf '%s\n' "$*" >> "$ssh_log"
    cat > "$ssh_stdin_log"
    return 0
  }

  run _db_push_mysql "$stack" "" "deploy" "1.2.3.4" "/remote/dir" "$backup_dir" "" "false" "single" ""

  [ "$status" -eq 0 ]
  # Password must never appear as an argv token to ssh...
  ! grep -q -- "s3cret-push-password" "$ssh_log"
  # ...it must travel over ssh's stdin instead.
  grep -q -- "s3cret-push-password" "$ssh_stdin_log"

  unset MYSQL_ROOT_PASSWORD MYSQL_DATABASE STRUT_YES
  rm -rf "$backup_dir"
}

@test "_db_push_mysql: a --file for a different engine is skipped silently under target=all (issue #387)" {
  local stack="test-mysql-push-skip-$$"
  local backup_dir="$TEST_TMP/mysql-push-skip"
  mkdir -p "$backup_dir"

  _db_push_upload() { echo "SHOULD NOT UPLOAD"; return 0; }
  ssh() { echo "SHOULD NOT SSH"; return 0; }

  run _db_push_mysql "$stack" "" "deploy" "1.2.3.4" "/remote/dir" "$backup_dir" "" "false" "all" "postgres-20260101-000000.sql"

  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD NOT UPLOAD"* ]]
  [[ "$output" != *"SHOULD NOT SSH"* ]]

  rm -rf "$backup_dir"
}

@test "_db_push_postgres: a --file for a different engine fails loudly when this engine was explicitly requested (issue #387)" {
  local stack="test-pg-push-mismatch-$$"
  local backup_dir="$TEST_TMP/pg-push-mismatch"
  mkdir -p "$backup_dir"

  _db_push_upload() { echo "SHOULD NOT UPLOAD"; return 1; }
  # This file's setup() overrides fail() to `return 1` (non-exiting) so
  # other tests can inspect graceful continuation. This test needs fail()'s
  # real `exit 1` semantics to verify the mismatch actually aborts before
  # upload — safe under `run`, which only captures the forked subshell's exit.
  fail() { echo "$1" >&2; exit 1; }

  run _db_push_postgres "$stack" "" "deploy" "1.2.3.4" "/remote/dir" "$backup_dir" "test-env" "" "false" "postgres" "mysql-20260101-000000.sql"

  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD NOT UPLOAD"* ]]
  [[ "$output" == *"does not match PostgreSQL backup naming"* ]]

  rm -rf "$backup_dir"
}

@test "_db_push_neo4j: restarts the service even when the remote load fails (issue #387)" {
  local stack="test-neo4j-push-$$"
  local backup_dir="$TEST_TMP/neo4j-push"
  mkdir -p "$backup_dir"
  echo "-- dump --" > "$backup_dir/neo4j-20260101-000000.dump"

  export STRUT_YES=1
  _db_push_upload() { return 0; }
  load_remote_backup_conf() { BACKUP_NEO4J_SERVICE="neo4j"; }
  resolve_deploy_dir() { echo "/opt/app"; }

  local ssh_log="$TEST_TMP/neo4j_ssh_argv.log"
  ssh() {
    printf '%s\n' "$*" >> "$ssh_log"
    case "$*" in
      *"database load neo4j"*) return 1 ;;  # simulate a failed load
      *) return 0 ;;
    esac
  }

  run _db_push_neo4j "$stack" "" "deploy" "1.2.3.4" "/remote/dir" "$backup_dir" "test-env" "" "false" "neo4j" ""

  [ "$status" -ne 0 ]
  [[ "$output" == *"Neo4j restore failed"* ]]
  # The load failed, but `start` must still have been issued as a separate call.
  grep -q "compose --project-name test-env start neo4j" "$ssh_log"
  # --from-path must be a directory, not the dump file itself.
  grep -q -- "--from-path=/var/lib/neo4j/import --overwrite-destination" "$ssh_log"

  unset STRUT_YES
  rm -rf "$backup_dir"
}
