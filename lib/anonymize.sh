#!/usr/bin/env bash
# ==================================================
# lib/anonymize.sh — Database anonymization engine
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Applies anonymization rules from anonymize.conf to a database
# after restore. Supports Postgres, MySQL, and SQLite.
#
# anonymize.conf format:
#   TABLE.COLUMN=strategy
#   users.email=fake_email
#   users.name=fake_name
#   users.phone=null

set -euo pipefail

# ── Strategy SQL generators ───────────────────────────────────────────────────

# _anon_sql_fake_email <table> <column> [db_type]
# Generates SQL to replace emails with user_<id>@example.com
_anon_sql_fake_email() {
  local table="$1" column="$2" db_type="${3:-postgres}"
  case "$db_type" in
    postgres) echo "UPDATE \"$table\" SET \"$column\" = 'user_' || id || '@example.com' WHERE \"$column\" IS NOT NULL;" ;;
    mysql)    echo "UPDATE \`$table\` SET \`$column\` = CONCAT('user_', id, '@example.com') WHERE \`$column\` IS NOT NULL;" ;;
    sqlite)   echo "UPDATE \"$table\" SET \"$column\" = 'user_' || rowid || '@example.com' WHERE \"$column\" IS NOT NULL;" ;;
  esac
}

# _anon_sql_fake_name <table> <column> [db_type]
_anon_sql_fake_name() {
  local table="$1" column="$2" db_type="${3:-postgres}"
  case "$db_type" in
    postgres) echo "UPDATE \"$table\" SET \"$column\" = 'User ' || id WHERE \"$column\" IS NOT NULL;" ;;
    mysql)    echo "UPDATE \`$table\` SET \`$column\` = CONCAT('User ', id) WHERE \`$column\` IS NOT NULL;" ;;
    sqlite)   echo "UPDATE \"$table\" SET \"$column\" = 'User ' || rowid WHERE \"$column\" IS NOT NULL;" ;;
  esac
}

# _anon_sql_null <table> <column> [db_type]
_anon_sql_null() {
  local table="$1" column="$2" db_type="${3:-postgres}"
  case "$db_type" in
    postgres) echo "UPDATE \"$table\" SET \"$column\" = NULL;" ;;
    mysql)    echo "UPDATE \`$table\` SET \`$column\` = NULL;" ;;
    sqlite)   echo "UPDATE \"$table\" SET \"$column\" = NULL;" ;;
  esac
}

# _anon_sql_mask <table> <column> [db_type]
# Keeps first and last char, replaces middle with ***
_anon_sql_mask() {
  local table="$1" column="$2" db_type="${3:-postgres}"
  case "$db_type" in
    postgres) echo "UPDATE \"$table\" SET \"$column\" = LEFT(\"$column\", 1) || '***' || RIGHT(\"$column\", 1) WHERE \"$column\" IS NOT NULL AND LENGTH(\"$column\") > 2;" ;;
    mysql)    echo "UPDATE \`$table\` SET \`$column\` = CONCAT(LEFT(\`$column\`, 1), '***', RIGHT(\`$column\`, 1)) WHERE \`$column\` IS NOT NULL AND LENGTH(\`$column\`) > 2;" ;;
    sqlite)   echo "UPDATE \"$table\" SET \"$column\" = SUBSTR(\"$column\", 1, 1) || '***' || SUBSTR(\"$column\", -1) WHERE \"$column\" IS NOT NULL AND LENGTH(\"$column\") > 2;" ;;
  esac
}

# _anon_sql_hash <table> <column> [db_type]
# One-way transform — preserves uniqueness, not reversible to plaintext.
# postgres/mysql use their native SHA-256 functions. Stock sqlite3 has no
# built-in crypto hash, so it uses a pure-SQL djb2-style rolling hash over a
# recursive CTE — a documented pseudonymization, not a cryptographic digest,
# but unlike HEX() it is lossy (fixed-width output, arithmetic overflow) and
# cannot be decoded back to the original value.
_anon_sql_hash() {
  local table="$1" column="$2" db_type="${3:-postgres}"
  case "$db_type" in
    postgres) echo "UPDATE \"$table\" SET \"$column\" = ENCODE(SHA256(\"$column\"::bytea), 'hex') WHERE \"$column\" IS NOT NULL;" ;;
    mysql)    echo "UPDATE \`$table\` SET \`$column\` = SHA2(\`$column\`, 256) WHERE \`$column\` IS NOT NULL;" ;;
    sqlite)   echo "UPDATE \"$table\" SET \"$column\" = (
  WITH RECURSIVE anon_hash_walk(i, h) AS (
    SELECT 1, 5381
    UNION ALL
    SELECT i + 1, ((h * 33) + unicode(substr(\"$table\".\"$column\", i, 1))) % 4294967296
    FROM anon_hash_walk
    WHERE i <= length(\"$table\".\"$column\")
  )
  SELECT printf('%08x%08x', h, (h * 2654435761) % 4294967296) FROM anon_hash_walk ORDER BY i DESC LIMIT 1
) WHERE \"$column\" IS NOT NULL;" ;;
  esac
}

# _anon_sql_fake_address <table> <column> [db_type]
_anon_sql_fake_address() {
  local table="$1" column="$2" db_type="${3:-postgres}"
  case "$db_type" in
    postgres) echo "UPDATE \"$table\" SET \"$column\" = id || ' Test Avenue' WHERE \"$column\" IS NOT NULL;" ;;
    mysql)    echo "UPDATE \`$table\` SET \`$column\` = CONCAT(id, ' Test Avenue') WHERE \`$column\` IS NOT NULL;" ;;
    sqlite)   echo "UPDATE \"$table\" SET \"$column\" = rowid || ' Test Avenue' WHERE \"$column\" IS NOT NULL;" ;;
  esac
}

# ── Core engine ───────────────────────────────────────────────────────────────

# _anon_generate_sql <strategy> <table> <column> <db_type>
# Echoes the SQL statement for a given strategy. `preserve` is the only
# intentional no-op (empty output, success). An unrecognized strategy is a
# config error, not a skip — anonymization exists to guarantee PII doesn't
# leave the room; silently skipping a typo'd rule would defeat that
# guarantee while still reporting "complete". Returns nonzero so callers
# abort before any SQL reaches the database.
_anon_generate_sql() {
  local strategy="$1" table="$2" column="$3" db_type="${4:-postgres}"

  case "$strategy" in
    fake_email)   _anon_sql_fake_email "$table" "$column" "$db_type" ;;
    fake_name)    _anon_sql_fake_name "$table" "$column" "$db_type" ;;
    null)         _anon_sql_null "$table" "$column" "$db_type" ;;
    mask)         _anon_sql_mask "$table" "$column" "$db_type" ;;
    hash)         _anon_sql_hash "$table" "$column" "$db_type" ;;
    fake_address) _anon_sql_fake_address "$table" "$column" "$db_type" ;;
    preserve)     echo "" ;;  # no-op
    *) error "Unknown anonymization strategy: $strategy"; return 1 ;;
  esac
}

# anon_parse_config <config_file>
# Parses anonymize.conf and outputs "table column strategy" lines to stdout.
# Skips comments and empty lines. A malformed TABLE.COLUMN key is fatal
# (returns nonzero after reporting all such lines) — same reasoning as an
# unrecognized strategy: a rule that's silently dropped from the plan is a
# column that was supposed to be anonymized and wasn't.
anon_parse_config() {
  local config_file="$1"

  [ -f "$config_file" ] || { error "anonymize.conf not found: $config_file"; return 1; }

  local had_error=false
  while IFS='=' read -r key strategy; do
    # Skip comments and empty lines
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$key" | xargs)
    strategy=$(echo "$strategy" | xargs)

    # Parse TABLE.COLUMN
    if [[ "$key" =~ ^([^.]+)\.(.+)$ ]]; then
      local table="${BASH_REMATCH[1]}"
      local column="${BASH_REMATCH[2]}"
      echo "$table $column $strategy"
    else
      error "Invalid anonymize.conf entry: $key=$strategy (expected TABLE.COLUMN=strategy)"
      had_error=true
    fi
  done < "$config_file"

  ! $had_error
}

# anon_build_sql <config_file> <db_type>
# Builds the full SQL script from anonymize.conf for a given database type.
# Outputs SQL to stdout. Fails (nonzero, no partial SQL trusted by the
# caller) on a malformed config entry or an unrecognized strategy — see
# anon_parse_config / _anon_generate_sql.
anon_build_sql() {
  local config_file="$1"
  local db_type="${2:-postgres}"

  local rules
  rules=$(anon_parse_config "$config_file") || return 1

  echo "-- Anonymization SQL generated by strut"
  echo "-- Config: $config_file"
  echo "-- Database type: $db_type"
  echo ""

  local rule_count=0

  while IFS=' ' read -r table column strategy; do
    [ -z "$table" ] && continue
    local sql
    sql=$(_anon_generate_sql "$strategy" "$table" "$column" "$db_type") || return 1
    if [ -n "$sql" ]; then
      echo "-- $table.$column → $strategy"
      echo "$sql"
      echo ""
      rule_count=$((rule_count + 1))
    fi
  done <<< "$rules"

  echo "-- $rule_count anonymization rules applied"
}

# anon_apply_postgres <stack> <compose_cmd> <config_file>
# Applies anonymization rules to a running Postgres database.
anon_apply_postgres() {
  local stack="$1"
  local compose_cmd="$2"
  local config_file="$3"

  local pg_service="${BACKUP_POSTGRES_SERVICE:-postgres}"
  local sql
  # Explicit `|| return 1` — under bash, errexit does NOT reliably propagate
  # through a failing command substitution nested inside another function's
  # own command substitution (anon_build_sql runs inside this `$(...)`,
  # which itself runs inside the caller's `$(anon_apply_postgres ...)`).
  # Without this, an unknown-strategy/malformed-config failure deep in
  # anon_build_sql would silently be swallowed and $sql would just be
  # whatever partial output was produced before the failure.
  sql=$(anon_build_sql "$config_file" "postgres") || { error "PostgreSQL anonymization aborted: invalid anonymize.conf"; return 1; }

  log "Applying anonymization rules to PostgreSQL..."
  echo "$sql" | $compose_cmd exec -T "$pg_service" \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}" 2>/dev/null \
    && ok "PostgreSQL anonymization complete" \
    || { error "PostgreSQL anonymization failed"; return 1; }
}

# anon_apply_mysql <stack> <compose_cmd> <config_file>
anon_apply_mysql() {
  local stack="$1"
  local compose_cmd="$2"
  local config_file="$3"

  local mysql_user="${MYSQL_USER:-root}"
  local mysql_password="${MYSQL_ROOT_PASSWORD:-${MYSQL_PASSWORD:-}}"
  local mysql_db="${MYSQL_DATABASE:-}"
  [ -n "$mysql_db" ] || fail "MYSQL_DATABASE not set in environment"
  local sql
  # See the matching comment in anon_apply_postgres — errexit alone doesn't
  # catch this nested command-substitution failure.
  sql=$(anon_build_sql "$config_file" "mysql") || { error "MySQL anonymization aborted: invalid anonymize.conf"; return 1; }

  log "Applying anonymization rules to MySQL..."
  # Pass the password via MYSQL_PWD, exported locally and referenced bare
  # (-e MYSQL_PWD, no =value) so it never appears as a literal argv token on
  # either the host (the docker/compose exec process) or in the container
  # (the mysql client process) — closes both `ps` surfaces. unset runs on
  # both success and failure so the export never leaks into later calls.
  export MYSQL_PWD="$mysql_password"
  local mysql_result=0
  echo "$sql" | $compose_cmd exec -T -e MYSQL_PWD mysql \
    mysql -u "$mysql_user" "$mysql_db" 2>/dev/null || mysql_result=1
  unset MYSQL_PWD
  if [ "$mysql_result" -eq 0 ]; then
    ok "MySQL anonymization complete"
  else
    error "MySQL anonymization failed"
    return 1
  fi
}

# anon_apply_sqlite <stack> <db_file> <config_file>
anon_apply_sqlite() {
  local stack="$1"
  local db_file="$2"
  local config_file="$3"

  local sql
  # See the matching comment in anon_apply_postgres — errexit alone doesn't
  # catch this nested command-substitution failure.
  sql=$(anon_build_sql "$config_file" "sqlite") || { error "SQLite anonymization aborted: invalid anonymize.conf"; return 1; }

  log "Applying anonymization rules to SQLite..."
  echo "$sql" | sqlite3 -bail "$db_file" 2>/dev/null \
    && ok "SQLite anonymization complete" \
    || { error "SQLite anonymization failed"; return 1; }
}

# anon_dry_run <config_file> <db_type>
# Shows what would be anonymized without making changes.
anon_dry_run() {
  local config_file="$1"
  local db_type="${2:-postgres}"

  echo ""
  echo -e "${YELLOW}[DRY-RUN] Anonymization plan:${NC}"
  echo ""

  local rule_count=0
  while IFS=' ' read -r table column strategy; do
    [ -z "$table" ] && continue
    echo -e "  ${YELLOW}[DRY-RUN]${NC} $table.$column → $strategy"
    rule_count=$((rule_count + 1))
  done < <(anon_parse_config "$config_file")

  echo ""
  echo -e "  $rule_count rule(s) would be applied"
  echo ""
  echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
}
