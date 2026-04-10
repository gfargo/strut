#!/usr/bin/env bats
# ==================================================
# tests/test_schema_helpers.bats — Tests for lib/schema.sh pure functions
# ==================================================
# Run:  bats tests/test_schema_helpers.bats
# Covers: extract_expected_objects_from_sql, build_expected_values_cte

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  source "$CLI_ROOT/lib/schema.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── extract_expected_objects_from_sql ─────────────────────────────────────────

@test "extract_expected_objects_from_sql: extracts simple CREATE TABLE names" {
  mkdir -p "$TEST_TMP/sql"
  cat > "$TEST_TMP/sql/01_schema.sql" <<'EOF'
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name TEXT
);
CREATE TABLE posts (
  id SERIAL PRIMARY KEY,
  user_id INT
);
EOF
  run extract_expected_objects_from_sql "$TEST_TMP/sql" "table"
  [ "$status" -eq 0 ]
  [[ "$output" == *"users"* ]]
  [[ "$output" == *"posts"* ]]
}

@test "extract_expected_objects_from_sql: handles IF NOT EXISTS" {
  mkdir -p "$TEST_TMP/sql"
  cat > "$TEST_TMP/sql/01.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS admin_users (
  id SERIAL PRIMARY KEY
);
EOF
  run extract_expected_objects_from_sql "$TEST_TMP/sql" "table"
  [ "$status" -eq 0 ]
  [[ "$output" == *"admin_users"* ]]
}

@test "extract_expected_objects_from_sql: extracts views" {
  mkdir -p "$TEST_TMP/sql"
  cat > "$TEST_TMP/sql/02.sql" <<'EOF'
CREATE VIEW active_users AS SELECT * FROM users WHERE active = true;
CREATE OR REPLACE VIEW user_stats AS SELECT COUNT(*) FROM users;
EOF
  run extract_expected_objects_from_sql "$TEST_TMP/sql" "view"
  [ "$status" -eq 0 ]
  [[ "$output" == *"active_users"* ]]
  [[ "$output" == *"user_stats"* ]]
}

@test "extract_expected_objects_from_sql: returns unique names across multiple files" {
  mkdir -p "$TEST_TMP/sql"
  cat > "$TEST_TMP/sql/01.sql" <<'EOF'
CREATE TABLE users (id SERIAL);
EOF
  cat > "$TEST_TMP/sql/02.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS users (id SERIAL);
CREATE TABLE posts (id SERIAL);
EOF
  run extract_expected_objects_from_sql "$TEST_TMP/sql" "table"
  [ "$status" -eq 0 ]
  # Should deduplicate — only 2 unique names
  local count
  count=$(echo "$output" | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "extract_expected_objects_from_sql: returns empty for missing directory" {
  run extract_expected_objects_from_sql "$TEST_TMP/nonexistent" "table"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_expected_objects_from_sql: fails on unknown object type" {
  mkdir -p "$TEST_TMP/sql"
  cat > "$TEST_TMP/sql/01.sql" <<'EOF'
CREATE TABLE foo (id INT);
EOF
  run extract_expected_objects_from_sql "$TEST_TMP/sql" "index"
  [ "$status" -eq 1 ]
}

@test "extract_expected_objects_from_sql: handles schema-qualified names" {
  mkdir -p "$TEST_TMP/sql"
  cat > "$TEST_TMP/sql/01.sql" <<'EOF'
CREATE TABLE public.events (id SERIAL);
CREATE TABLE public.sessions (id SERIAL);
EOF
  run extract_expected_objects_from_sql "$TEST_TMP/sql" "table"
  [ "$status" -eq 0 ]
  [[ "$output" == *"events"* ]]
  [[ "$output" == *"sessions"* ]]
}

@test "extract_expected_objects_from_sql: works with fixture SQL directory" {
  mkdir -p "$TEST_TMP/sql/init"
  cat > "$TEST_TMP/sql/init/01_schema.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, name TEXT);
CREATE TABLE IF NOT EXISTS sessions (id SERIAL PRIMARY KEY, user_id INT);
EOF
  run extract_expected_objects_from_sql "$TEST_TMP/sql/init" "table"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"users"* ]]
  [[ "$output" == *"sessions"* ]]
}

# ── build_expected_values_cte ─────────────────────────────────────────────────

@test "build_expected_values_cte: builds single-item CTE" {
  run build_expected_values_cte "table" "users"
  [ "$status" -eq 0 ]
  [[ "$output" == "WITH expected(name) AS ( VALUES ('users') )" ]]
}

@test "build_expected_values_cte: builds multi-item CTE" {
  run build_expected_values_cte "table" "users" "posts" "comments"
  [ "$status" -eq 0 ]
  [[ "$output" == "WITH expected(name) AS ( VALUES ('users'), ('posts'), ('comments') )" ]]
}
