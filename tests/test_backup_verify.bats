#!/usr/bin/env bats
# ==================================================
# tests/test_backup_verify.bats — Tests for lib/backup/verify.sh
# ==================================================
# Run:  bats tests/test_backup_verify.bats
# Covers: verify_postgres_backup, verify_mysql_backup, verify_sqlite_backup,
# and the empty-file fast-fail path for verify_neo4j_backup(_full).
#
# Neo4j's structural/full checks require a real Docker + Neo4j image, so they
# are not exercised here — only the pre-Docker empty-file guard is covered.
# See the manual test plan in the PR description for Docker-based coverage.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  confirm() { return 0; }

  source "$CLI_ROOT/lib/backup/engines.sh"
  source "$CLI_ROOT/lib/backup/verify.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── verify_sqlite_backup ───────────────────────────────────────────────────────

@test "verify_sqlite_backup: fails for empty file" {
  local f="$TEST_TMP/sqlite-empty.db"
  : > "$f"

  run verify_sqlite_backup "test-stack" "$f"
  [ "$status" -eq 1 ]
}

@test "verify_sqlite_backup: passes for a valid database with a table" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"

  local f="$TEST_TMP/sqlite-valid.db"
  sqlite3 "$f" "CREATE TABLE widgets (id INTEGER PRIMARY KEY); INSERT INTO widgets VALUES (1);"

  run verify_sqlite_backup "test-stack" "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tables_verified":1'* ]]
}

@test "verify_sqlite_backup: fails integrity check on a corrupt database" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"

  local f="$TEST_TMP/sqlite-corrupt.db"
  sqlite3 "$f" "CREATE TABLE widgets (id INTEGER PRIMARY KEY); INSERT INTO widgets VALUES (1);"
  # Zero out a chunk of the first page past the 100-byte file header,
  # destroying the b-tree structure while keeping the file size (and the
  # size-based check) intact — PRAGMA integrity_check must catch this.
  dd if=/dev/zero of="$f" bs=1 seek=100 count=300 conv=notrunc 2>/dev/null

  run verify_sqlite_backup "test-stack" "$f"
  [ "$status" -eq 1 ]
}

# ── verify_postgres_backup ─────────────────────────────────────────────────────

@test "verify_postgres_backup: fails for empty file" {
  local f="$TEST_TMP/postgres-empty.sql"
  : > "$f"

  run verify_postgres_backup "test-stack" "$f" "should_not_be_called"
  [ "$status" -eq 1 ]
}

@test "verify_postgres_backup: fails on a truncated dump missing the completion marker, without touching compose_cmd" {
  local f="$TEST_TMP/postgres-truncated.sql"
  cat > "$f" <<'EOF'
CREATE TABLE widgets (id integer);
EOF

  should_not_be_called() { echo "SHOULD NOT BE CALLED"; return 1; }

  run verify_postgres_backup "test-stack" "$f" "should_not_be_called"
  [ "$status" -eq 1 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

@test "verify_postgres_backup: passes the trailer check and restores when the dump is complete" {
  local f="$TEST_TMP/postgres-complete.sql"
  cat > "$f" <<'EOF'
CREATE TABLE widgets (id integer);
-- PostgreSQL database dump complete
EOF

  stub_compose_cmd() {
    case "$*" in
      *"SELECT COUNT(*)"*) echo "1" ;;
      *"SELECT SUM(n_live_tup)"*) echo "3" ;;
      *) return 0 ;;
    esac
  }

  run verify_postgres_backup "test-stack" "$f" "stub_compose_cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tables_verified":1'* ]]
}

@test "verify_postgres_backup: honors BACKUP_POSTGRES_SERVICE, not a hardcoded 'postgres' service (issue #389)" {
  local f="$TEST_TMP/postgres-complete.sql"
  cat > "$f" <<'EOF'
CREATE TABLE widgets (id integer);
-- PostgreSQL database dump complete
EOF

  export BACKUP_POSTGRES_SERVICE="db"

  # Only responds when exec'd against the configured service name — if
  # verify_postgres_backup fell back to a hardcoded "postgres" service,
  # this stub returns nonzero and verification fails.
  stub_compose_cmd() {
    case "$*" in
      *"exec -T db "*"SELECT COUNT(*)"*) echo "1" ;;
      *"exec -T db "*"SELECT SUM(n_live_tup)"*) echo "3" ;;
      *"exec -T db "*) return 0 ;;
      *) return 1 ;;
    esac
  }

  run verify_postgres_backup "test-stack" "$f" "stub_compose_cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tables_verified":1'* ]]

  unset BACKUP_POSTGRES_SERVICE
}

# ── verify_mysql_backup ────────────────────────────────────────────────────────

@test "verify_mysql_backup: fails for empty file" {
  local f="$TEST_TMP/mysql-empty.sql"
  : > "$f"

  run verify_mysql_backup "test-stack" "$f" "should_not_be_called"
  [ "$status" -eq 1 ]
}

@test "verify_mysql_backup: fails on a truncated dump missing the completion marker, without touching compose_cmd" {
  local f="$TEST_TMP/mysql-truncated.sql"
  cat > "$f" <<'EOF'
CREATE TABLE widgets (id int);
EOF

  should_not_be_called() { echo "SHOULD NOT BE CALLED"; return 1; }

  run verify_mysql_backup "test-stack" "$f" "should_not_be_called"
  [ "$status" -eq 1 ]
  [[ "$output" != *"SHOULD NOT BE CALLED"* ]]
}

@test "verify_mysql_backup: passes the trailer check and restores when the dump is complete" {
  local f="$TEST_TMP/mysql-complete.sql"
  cat > "$f" <<'EOF'
CREATE TABLE widgets (id int);
-- Dump completed on 2026-07-04 12:00:00
EOF

  stub_compose_cmd() {
    case "$*" in
      *"SELECT COUNT(*)"*) echo "1" ;;
      *) return 0 ;;
    esac
  }

  run verify_mysql_backup "test-stack" "$f" "stub_compose_cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tables_verified":1'* ]]
}

# ── verify_neo4j_backup / verify_neo4j_backup_full ────────────────────────────
# Structural/full checks require Docker + a real Neo4j image and are not
# exercised in this suite — only the pre-Docker empty-file guard is covered.

@test "verify_neo4j_backup: fails for empty file (no Docker required)" {
  local f="$TEST_TMP/neo4j-empty.dump"
  : > "$f"

  run verify_neo4j_backup "test-stack" "$f" "should_not_be_called"
  [ "$status" -eq 1 ]
}

@test "verify_neo4j_backup_full: fails for empty file (no Docker required)" {
  local f="$TEST_TMP/neo4j-empty.dump"
  : > "$f"

  run verify_neo4j_backup_full "test-stack" "$f" "should_not_be_called"
  [ "$status" -eq 1 ]
}
