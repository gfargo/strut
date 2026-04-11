#!/usr/bin/env bats
# ==================================================
# tests/test_anonymize.bats — Tests for data anonymization engine
# ==================================================
# Run:  bats tests/test_anonymize.bats
# Covers: anon_parse_config, anon_build_sql, _anon_generate_sql, anon_dry_run

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/anonymize.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── _anon_generate_sql per strategy ──────────────────────────────────────────

@test "fake_email: generates correct Postgres SQL" {
  local sql
  sql=$(_anon_generate_sql "fake_email" "users" "email" "postgres")
  [[ "$sql" == *"UPDATE"* ]]
  [[ "$sql" == *"users"* ]]
  [[ "$sql" == *"@example.com"* ]]
}

@test "fake_email: generates correct MySQL SQL" {
  local sql
  sql=$(_anon_generate_sql "fake_email" "users" "email" "mysql")
  [[ "$sql" == *"CONCAT"* ]]
  [[ "$sql" == *"@example.com"* ]]
}

@test "fake_email: generates correct SQLite SQL" {
  local sql
  sql=$(_anon_generate_sql "fake_email" "users" "email" "sqlite")
  [[ "$sql" == *"rowid"* ]]
  [[ "$sql" == *"@example.com"* ]]
}

@test "fake_name: generates UPDATE with User prefix" {
  local sql
  sql=$(_anon_generate_sql "fake_name" "users" "name" "postgres")
  [[ "$sql" == *"User "* ]]
  [[ "$sql" == *"UPDATE"* ]]
}

@test "null: generates SET NULL" {
  local sql
  sql=$(_anon_generate_sql "null" "users" "phone" "postgres")
  [[ "$sql" == *"SET"* ]]
  [[ "$sql" == *"NULL"* ]]
}

@test "mask: generates masking SQL" {
  local sql
  sql=$(_anon_generate_sql "mask" "payments" "card_number" "postgres")
  [[ "$sql" == *"LEFT"* ]]
  [[ "$sql" == *"***"* ]]
}

@test "hash: generates SHA256 SQL for Postgres" {
  local sql
  sql=$(_anon_generate_sql "hash" "users" "email" "postgres")
  [[ "$sql" == *"SHA256"* ]]
}

@test "hash: generates SHA2 SQL for MySQL" {
  local sql
  sql=$(_anon_generate_sql "hash" "users" "email" "mysql")
  [[ "$sql" == *"SHA2"* ]]
}

@test "fake_address: generates address replacement" {
  local sql
  sql=$(_anon_generate_sql "fake_address" "orders" "address" "postgres")
  [[ "$sql" == *"Test Avenue"* ]]
}

@test "preserve: returns empty string (no-op)" {
  local sql
  sql=$(_anon_generate_sql "preserve" "users" "id" "postgres")
  [ -z "$sql" ]
}

@test "unknown strategy: returns empty string" {
  local sql
  sql=$(_anon_generate_sql "unknown_strategy" "users" "email" "postgres")
  [ -z "$sql" ]
}

# ── anon_parse_config ─────────────────────────────────────────────────────────

@test "anon_parse_config: parses TABLE.COLUMN=strategy format" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
users.name=fake_name
orders.address=fake_address
EOF

  run anon_parse_config "$TEST_TMP/anonymize.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"users email fake_email"* ]]
  [[ "$output" == *"users name fake_name"* ]]
  [[ "$output" == *"orders address fake_address"* ]]
}

@test "anon_parse_config: skips comments and empty lines" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
# This is a comment
users.email=fake_email

# Another comment
users.name=fake_name
EOF

  run anon_parse_config "$TEST_TMP/anonymize.conf"
  [ "$status" -eq 0 ]
  local line_count
  line_count=$(echo "$output" | grep -c "^users" || true)
  [ "$line_count" -eq 2 ]
}

@test "anon_parse_config: fails for missing file" {
  run anon_parse_config "$TEST_TMP/nonexistent.conf"
  [ "$status" -eq 1 ]
}

@test "anon_parse_config: warns on invalid format" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
invalid_no_dot=fake_email
EOF

  run anon_parse_config "$TEST_TMP/anonymize.conf"
  [[ "$output" == *"Invalid"* ]]
}

# ── anon_build_sql ────────────────────────────────────────────────────────────

@test "anon_build_sql: generates complete SQL script for Postgres" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
users.phone=null
payments.card=mask
EOF

  run anon_build_sql "$TEST_TMP/anonymize.conf" "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Anonymization SQL"* ]]
  [[ "$output" == *"UPDATE"* ]]
  [[ "$output" == *"@example.com"* ]]
  [[ "$output" == *"NULL"* ]]
  [[ "$output" == *"***"* ]]
  [[ "$output" == *"3 anonymization rules"* ]]
}

@test "anon_build_sql: generates MySQL syntax" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
EOF

  run anon_build_sql "$TEST_TMP/anonymize.conf" "mysql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONCAT"* ]]
}

@test "anon_build_sql: skips preserve strategy" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.id=preserve
users.email=fake_email
EOF

  run anon_build_sql "$TEST_TMP/anonymize.conf" "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 anonymization rules"* ]]
}

# ── anon_dry_run ──────────────────────────────────────────────────────────────

@test "anon_dry_run: shows plan without executing" {
  cat > "$TEST_TMP/anonymize.conf" <<'EOF'
users.email=fake_email
users.name=fake_name
orders.address=fake_address
EOF

  run anon_dry_run "$TEST_TMP/anonymize.conf" "postgres"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"users.email"* ]]
  [[ "$output" == *"fake_email"* ]]
  [[ "$output" == *"3 rule(s)"* ]]
  [[ "$output" == *"No changes made"* ]]
}

# ── Property: all strategies generate valid SQL ───────────────────────────────

@test "Property: all strategies generate non-empty SQL for all DB types (except preserve)" {
  local strategies=("fake_email" "fake_name" "null" "mask" "hash" "fake_address")
  local db_types=("postgres" "mysql" "sqlite")

  for strategy in "${strategies[@]}"; do
    for db_type in "${db_types[@]}"; do
      local sql
      sql=$(_anon_generate_sql "$strategy" "test_table" "test_col" "$db_type")
      [ -n "$sql" ] || {
        echo "FAILED: strategy=$strategy db_type=$db_type returned empty SQL"
        return 1
      }
      [[ "$sql" == *"UPDATE"* ]] || {
        echo "FAILED: strategy=$strategy db_type=$db_type missing UPDATE keyword"
        return 1
      }
    done
  done
}

# ── Property: parse_config round-trips correctly ─────────────────────────────

@test "Property: random valid configs parse correctly (100 iterations)" {
  local tables=("users" "orders" "payments" "accounts" "profiles")
  local columns=("email" "name" "phone" "address" "card_number" "ssn")
  local strategies=("fake_email" "fake_name" "null" "mask" "hash" "fake_address" "preserve")

  for i in $(seq 1 100); do
    local table="${tables[$((RANDOM % ${#tables[@]}))]}"
    local column="${columns[$((RANDOM % ${#columns[@]}))]}"
    local strategy="${strategies[$((RANDOM % ${#strategies[@]}))]}"

    echo "$table.$column=$strategy" > "$TEST_TMP/anon-$i.conf"

    local parsed
    parsed=$(anon_parse_config "$TEST_TMP/anon-$i.conf")

    [[ "$parsed" == *"$table $column $strategy"* ]] || {
      echo "FAILED iteration $i: expected '$table $column $strategy', got '$parsed'"
      return 1
    }

    rm -f "$TEST_TMP/anon-$i.conf"
  done
}

# ── Scaffold includes anonymize.conf ──────────────────────────────────────────

@test "scaffold: creates anonymize.conf template" {
  source "$CLI_ROOT/lib/cmd_scaffold.sh"

  local stack_name="test-anon-scaffold-$$"
  run cmd_scaffold "$stack_name"
  [ "$status" -eq 0 ]

  local anon_file="$CLI_ROOT/stacks/$stack_name/anonymize.conf"
  [ -f "$anon_file" ]
  grep -q "TABLE.COLUMN=strategy" "$anon_file"
  grep -q "fake_email" "$anon_file"
  grep -q "fake_name" "$anon_file"
  grep -q "null" "$anon_file"
  grep -q "mask" "$anon_file"

  rm -rf "$CLI_ROOT/stacks/$stack_name"
}
