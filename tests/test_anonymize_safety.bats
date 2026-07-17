#!/usr/bin/env bats
# ==================================================
# tests/test_anonymize_safety.bats — Regression tests for OSS-437 / #233
# ==================================================
# Proves: anon_apply_* paths report failure (not "complete") when an
# anonymization statement errors, the MySQL password never lands on the
# command line, and the SQLite "hash" strategy is not a reversible HEX()
# encoding.
# Run:  bats tests/test_anonymize_safety.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/anonymize.sh"

  COMPOSE_CALL_LOG="$TEST_TMP/compose_calls.log"
  : > "$COMPOSE_CALL_LOG"

  # fake_compose stands in for `docker compose ...`. It records every
  # invocation so tests can assert on the exact flags/args used, and fails
  # when FAKE_ANON_FAIL=1 to simulate a bad anonymize statement erroring
  # inside psql/mysql (e.g. a nonexistent column).
  fake_compose() {
    echo "$*" >> "$COMPOSE_CALL_LOG"
    [ "${FAKE_ANON_FAIL:-0}" = "1" ] && return 1
    return 0
  }
  export -f fake_compose
}

teardown() {
  common_teardown
}

# ── anon_apply_postgres ────────────────────────────────────────────────────

@test "anon_apply_postgres: fails and does not report complete when a statement errors" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.bad_column=hash
EOF

  FAKE_ANON_FAIL=1 run anon_apply_postgres "test-stack" "fake_compose" "$TEST_TMP/anonymize.conf"
  [ "$status" -ne 0 ]
  [[ "$output" != *"complete"* ]]
  [[ "$output" == *"failed"* ]]
}

@test "anon_apply_postgres: reports success when all statements apply" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
EOF

  run anon_apply_postgres "test-stack" "fake_compose" "$TEST_TMP/anonymize.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"complete"* ]]
}

@test "anon_apply_postgres: sets ON_ERROR_STOP=1 so psql aborts on the first failed statement" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
EOF

  run anon_apply_postgres "test-stack" "fake_compose" "$TEST_TMP/anonymize.conf"
  [ "$status" -eq 0 ]
  grep -q "ON_ERROR_STOP=1" "$COMPOSE_CALL_LOG"
}

# ── anon_apply_mysql ────────────────────────────────────────────────────────

@test "anon_apply_mysql: fails and does not report complete when a statement errors" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.bad_column=hash
EOF

  MYSQL_ROOT_PASSWORD="s3cret" FAKE_ANON_FAIL=1 run anon_apply_mysql "test-stack" "fake_compose" "$TEST_TMP/anonymize.conf"
  [ "$status" -ne 0 ]
  [[ "$output" != *"complete"* ]]
  [[ "$output" == *"failed"* ]]
}

@test "anon_apply_mysql: reports success when all statements apply" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
EOF

  MYSQL_ROOT_PASSWORD="s3cret" run anon_apply_mysql "test-stack" "fake_compose" "$TEST_TMP/anonymize.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"complete"* ]]
}

@test "anon_apply_mysql: never passes --password= to the mysql client" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
EOF

  MYSQL_ROOT_PASSWORD="s3cret-password" run anon_apply_mysql "test-stack" "fake_compose" "$TEST_TMP/anonymize.conf"
  [ "$status" -eq 0 ]
  ! grep -q -- "--password=" "$COMPOSE_CALL_LOG"
  # Password travels via a bare `-e MYSQL_PWD` (inherited from the local
  # shell env) — the literal secret must never appear in the exec argv log.
  grep -q -- "-e MYSQL_PWD" "$COMPOSE_CALL_LOG"
  ! grep -q -- "s3cret-password" "$COMPOSE_CALL_LOG"
}

# ── anon_apply_sqlite ───────────────────────────────────────────────────────

@test "anon_apply_sqlite: fails, reports no false success, and makes no partial writes on a bad column" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"

  local db="$TEST_TMP/test.db"
  sqlite3 "$db" "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);"
  sqlite3 "$db" "INSERT INTO users (id, email) VALUES (1, 'alice@example.com');"

  # The bad column errors first; -bail must stop before the valid
  # users.email statement that follows it ever runs.
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.nonexistent_column=hash
users.email=fake_email
EOF

  run anon_apply_sqlite "test-stack" "$db" "$TEST_TMP/anonymize.conf"
  [ "$status" -ne 0 ]
  [[ "$output" != *"complete"* ]]

  run sqlite3 "$db" "SELECT email FROM users WHERE id=1;"
  [ "$output" = "alice@example.com" ]
}

@test "anon_apply_sqlite: reports success when all statements apply" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"

  local db="$TEST_TMP/ok.db"
  sqlite3 "$db" "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);"
  sqlite3 "$db" "INSERT INTO users (id, email) VALUES (1, 'alice@example.com');"

  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
EOF

  run anon_apply_sqlite "test-stack" "$db" "$TEST_TMP/anonymize.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"complete"* ]]
}

@test "anon_apply_sqlite: hash strategy is not a reversible HEX() encoding" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"

  local db="$TEST_TMP/hash.db"
  sqlite3 "$db" "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);"
  sqlite3 "$db" "INSERT INTO users (id, email) VALUES
    (1, 'alice@example.com'), (2, 'bob@x.io'), (3, 'alice@example.com');"

  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=hash
EOF

  run anon_apply_sqlite "test-stack" "$db" "$TEST_TMP/anonymize.conf"
  [ "$status" -eq 0 ]

  local hash1 hash2 hash3 hex1
  hash1=$(sqlite3 "$db" "SELECT email FROM users WHERE id=1;")
  hash2=$(sqlite3 "$db" "SELECT email FROM users WHERE id=2;")
  hash3=$(sqlite3 "$db" "SELECT email FROM users WHERE id=3;")
  hex1=$(printf '%s' "alice@example.com" | od -An -tx1 | tr -d ' \n')

  # Not a reversible encoding: HEX() would keep a 1:1 length mapping to the
  # input and decode straight back to plaintext.
  [ "$hash1" != "alice@example.com" ]
  [ "$hash1" != "$hex1" ]
  [ "${#hash1}" -eq 16 ]
  [ "${#hash2}" -eq 16 ]

  # Deterministic (same input -> same hash) and distinct inputs diverge.
  [ "$hash1" = "$hash3" ]
  [ "$hash1" != "$hash2" ]
}

# ── Property: bad column name fails the command on every backend ───────────

@test "Property: a bad column name fails the command for every DB backend (postgres, mysql, sqlite)" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.bad_column=hash
EOF

  : > "$COMPOSE_CALL_LOG"
  FAKE_ANON_FAIL=1 run anon_apply_postgres "test-stack" "fake_compose" "$TEST_TMP/anonymize.conf"
  [ "$status" -ne 0 ]
  [[ "$output" != *"complete"* ]]

  : > "$COMPOSE_CALL_LOG"
  MYSQL_ROOT_PASSWORD="s3cret" FAKE_ANON_FAIL=1 run anon_apply_mysql "test-stack" "fake_compose" "$TEST_TMP/anonymize.conf"
  [ "$status" -ne 0 ]
  [[ "$output" != *"complete"* ]]

  if command -v sqlite3 >/dev/null 2>&1; then
    local db="$TEST_TMP/property.db"
    sqlite3 "$db" "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);"
    run anon_apply_sqlite "test-stack" "$db" "$TEST_TMP/anonymize.conf"
    [ "$status" -ne 0 ]
    [[ "$output" != *"complete"* ]]
  fi
}
