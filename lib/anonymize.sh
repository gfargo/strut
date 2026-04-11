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
# SHA256 hash — preserves uniqueness
_anon_sql_hash() {
  local table="$1" column="$2" db_type="${3:-postgres}"
  case "$db_type" in
    postgres) echo "UPDATE \"$table\" SET \"$column\" = ENCODE(SHA256(\"$column\"::bytea), 'hex') WHERE \"$column\" IS NOT NULL;" ;;
    mysql)    echo "UPDATE \`$table\` SET \`$column\` = SHA2(\`$column\`, 256) WHERE \`$column\` IS NOT NULL;" ;;
    sqlite)   echo "UPDATE \"$table\" SET \"$column\" = HEX(\"$column\") WHERE \"$column\" IS NOT NULL;" ;;
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
# Returns the SQL statement for a given strategy, or empty on error.
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
    *) error "Unknown anonymization strategy: $strategy"; echo "" ;;
  esac
}

# anon_parse_config <config_file>
# Parses anonymize.conf and outputs "table column strategy" lines to stdout.
# Skips comments and empty lines.
anon_parse_config() {
  local config_file="$1"

  [ -f "$config_file" ] || { error "anonymize.conf not found: $config_file"; return 1; }

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
      warn "Invalid anonymize.conf entry: $key=$strategy (expected TABLE.COLUMN=strategy)"
    fi
  done < "$config_file"
}

# anon_build_sql <config_file> <db_type>
# Builds the full SQL script from anonymize.conf for a given database type.
# Outputs SQL to stdout.
anon_build_sql() {
  local config_file="$1"
  local db_type="${2:-postgres}"

  echo "-- Anonymization SQL generated by strut"
  echo "-- Config: $config_file"
  echo "-- Database type: $db_type"
  echo ""

  local rule_count=0

  while IFS=' ' read -r table column strategy; do
    [ -z "$table" ] && continue
    local sql
    sql=$(_anon_generate_sql "$strategy" "$table" "$column" "$db_type")
    if [ -n "$sql" ]; then
      echo "-- $table.$column → $strategy"
      echo "$sql"
      echo ""
      rule_count=$((rule_count + 1))
    fi
  done < <(anon_parse_config "$config_file")

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
  sql=$(anon_build_sql "$config_file" "postgres")

  log "Applying anonymization rules to PostgreSQL..."
  echo "$sql" | $compose_cmd exec -T "$pg_service" \
    psql -U "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-app_db}" 2>/dev/null \
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
  local sql
  sql=$(anon_build_sql "$config_file" "mysql")

  log "Applying anonymization rules to MySQL..."
  echo "$sql" | $compose_cmd exec -T mysql \
    mysql -u "$mysql_user" --password="$mysql_password" "${MYSQL_DATABASE:-app_db}" 2>/dev/null \
    && ok "MySQL anonymization complete" \
    || { error "MySQL anonymization failed"; return 1; }
}

# anon_apply_sqlite <stack> <db_file> <config_file>
anon_apply_sqlite() {
  local stack="$1"
  local db_file="$2"
  local config_file="$3"

  local sql
  sql=$(anon_build_sql "$config_file" "sqlite")

  log "Applying anonymization rules to SQLite..."
  echo "$sql" | sqlite3 "$db_file" 2>/dev/null \
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
