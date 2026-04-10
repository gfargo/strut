#!/usr/bin/env bash
# ==================================================
# lib/schema.sh — Postgres schema apply/verify helpers
# ==================================================
# Requires: lib/utils.sh sourced first

set -euo pipefail

# extract_expected_objects_from_sql <sql_dir> <object_type>
#
# Parses SQL files in a directory and extracts CREATE TABLE or CREATE VIEW
# names using regex. Returns a sorted, unique list of unqualified object names.
#
# Args:
#   sql_dir     — Directory containing .sql files to scan
#   object_type — "table" or "view"
#
# Returns: 0 on success, 1 on unknown object_type; outputs names to stdout
extract_expected_objects_from_sql() {
  local sql_dir="$1"
  local object_type="$2" # table|view

  [ -d "$sql_dir" ] || return 0

  local sed_expr=""
  case "$object_type" in
    table)
      sed_expr='s/.*CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+("?[A-Za-z_][A-Za-z0-9_]*"?)(\.[\"A-Za-z_][A-Za-z0-9_]*\"?)?.*/\2\3/ip'
      ;;
    view)
      sed_expr='s/.*CREATE([[:space:]]+OR[[:space:]]+REPLACE)?[[:space:]]+VIEW([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+("?[A-Za-z_][A-Za-z0-9_]*"?)(\.[\"A-Za-z_][A-Za-z0-9_]*\"?)?.*/\3\4/ip'
      ;;
    *)
      return 1
      ;;
  esac

  # Extract object names from stack SQL files. This is intentionally permissive and
  # schema-agnostic; it supports unquoted names and common quoted identifiers.
  find "$sql_dir" -maxdepth 1 -type f -name "*.sql" -print0 \
    | xargs -0 sed -nE "$sed_expr" \
    | sed -E 's/"//g' \
    | sed -E 's/[;(].*$//' \
    | sed -E 's/^[^.]+\.//' \
    | sort -u
}

# build_expected_values_cte <kind> <items...>
#
# Builds a SQL CTE (Common Table Expression) of the form
# "WITH expected(name) AS (VALUES ('a'), ('b'), ...)" from the given items.
# Used to compare expected objects against the live database.
#
# Args:
#   kind  — Label for the CTE (currently unused in output, reserved)
#   items — One or more object names to include
#
# Returns: 0; outputs the CTE string to stdout
build_expected_values_cte() {
  local kind="$1"
  shift
  local items=("$@")

  local cte="WITH expected(name) AS ("
  local first=true
  local item
  for item in "${items[@]}"; do
    if $first; then
      cte="${cte} VALUES ('${item}')"
      first=false
    else
      cte="${cte}, ('${item}')"
    fi
  done
  cte="${cte} )"
  echo "$cte"
}

# postgres_apply_init_sql <stack> <compose_cmd> <stack_dir>
#
# Applies all SQL files from a stack's sql/init/ directory to the Postgres
# container, in sorted filename order. Each file is piped through psql with
# ON_ERROR_STOP=1 so failures are immediately fatal.
#
# Args:
#   stack       — Stack name (used for logging)
#   compose_cmd — Full docker compose command prefix
#   stack_dir   — Path to the stack directory (must contain sql/init/*.sql)
#
# Requires env: POSTGRES_USER (default: postgres), POSTGRES_DB (default: app_db)
# Returns: 0 on success; calls fail() on missing dir or files
# Side effects: Executes SQL DDL/DML against the Postgres container
postgres_apply_init_sql() {
  local stack="$1"
  local compose_cmd="$2"
  local stack_dir="$3"
  local sql_dir="$stack_dir/sql/init"

  [ -d "$sql_dir" ] || fail "SQL init directory not found: $sql_dir"

  local sql_files=()
  while IFS= read -r -d '' file; do
    sql_files+=("$file")
  done < <(find "$sql_dir" -maxdepth 1 -type f -name "*.sql" -print0 | sort -z)

  [ "${#sql_files[@]}" -gt 0 ] || fail "No SQL files found in: $sql_dir"

  log "Applying Postgres schema files for stack '$stack' from: $sql_dir"
  for sql_file in "${sql_files[@]}"; do
    log "Applying $(basename "$sql_file")"
    $compose_cmd exec -T postgres \
      psql -v ON_ERROR_STOP=1 \
      -U "${POSTGRES_USER:-postgres}" \
      -d "${POSTGRES_DB:-app_db}" \
      < "$sql_file"
  done

  ok "Postgres schema apply complete"
}

# postgres_verify_schema <stack> <compose_cmd>
#
# Verifies that all tables and views declared in a stack's sql/init/ files
# exist in the live Postgres database. Prints row counts for each object and
# a summary of the public schema inventory (tables, views, indexes).
#
# Args:
#   stack       — Stack name (used to locate sql/init/ under CLI_ROOT/stacks/)
#   compose_cmd — Full docker compose command prefix
#
# Requires env: CLI_ROOT, POSTGRES_USER (default: postgres),
#   POSTGRES_DB (default: app_db)
# Returns: 0 on success; calls fail() if expected objects are missing
# Side effects: Queries the Postgres container; prints verification report to stdout
postgres_verify_schema() {
  local stack="$1"
  local compose_cmd="$2"
  local stack_dir="$CLI_ROOT/stacks/$stack"
  local sql_dir="$stack_dir/sql/init"
  local db_user="${POSTGRES_USER:-postgres}"
  local db_name="${POSTGRES_DB:-app_db}"
  local expected_tables=()
  local expected_views=()

  log "Verifying Postgres schema for stack '$stack'"
  [ -d "$sql_dir" ] || fail "SQL init directory not found: $sql_dir"

  while IFS= read -r table_name; do
    [ -n "$table_name" ] && expected_tables+=("$table_name")
  done < <(extract_expected_objects_from_sql "$sql_dir" "table")

  while IFS= read -r view_name; do
    [ -n "$view_name" ] && expected_views+=("$view_name")
  done < <(extract_expected_objects_from_sql "$sql_dir" "view")

  echo ""
  echo "Expected objects derived from SQL init files: $sql_dir"
  echo "------------------------------------------------------"
  echo "  Tables: ${#expected_tables[@]}"
  echo "  Views:  ${#expected_views[@]}"

  if [ "${#expected_tables[@]}" -eq 0 ] && [ "${#expected_views[@]}" -eq 0 ]; then
    warn "No CREATE TABLE/VIEW statements detected in stack SQL files"
  fi

  if [ "${#expected_tables[@]}" -gt 0 ]; then
    local table_cte
    table_cte=$(build_expected_values_cte "table" "${expected_tables[@]}")
    local missing_tables
    missing_tables=$(
      $compose_cmd exec -T postgres \
        psql -v ON_ERROR_STOP=1 -t -A \
        -U "$db_user" \
        -d "$db_name" \
        -c "
${table_cte}
SELECT e.name
FROM expected e
LEFT JOIN information_schema.tables t
  ON t.table_schema = 'public' AND t.table_name = e.name
WHERE t.table_name IS NULL
ORDER BY e.name;"
    )

    if [ -n "$missing_tables" ]; then
      error "Missing expected tables:"
      echo "$missing_tables" | sed 's/^/  - /'
      fail "Schema verification failed"
    fi
  fi

  if [ "${#expected_views[@]}" -gt 0 ]; then
    local view_cte
    view_cte=$(build_expected_values_cte "view" "${expected_views[@]}")
    local missing_views
    missing_views=$(
      $compose_cmd exec -T postgres \
        psql -v ON_ERROR_STOP=1 -t -A \
        -U "$db_user" \
        -d "$db_name" \
        -c "
${view_cte}
SELECT e.name
FROM expected e
LEFT JOIN information_schema.views v
  ON v.table_schema = 'public' AND v.table_name = e.name
WHERE v.table_name IS NULL
ORDER BY e.name;"
    )

    if [ -n "$missing_views" ]; then
      error "Missing expected views:"
      echo "$missing_views" | sed 's/^/  - /'
      fail "Schema verification failed"
    fi
  fi

  ok "Required tables/views exist"

  echo ""
  echo "Schema verification details (database: $db_name)"
  echo "-----------------------------------------------"
  for table_name in "${expected_tables[@]}"; do
    local row_count
    row_count=$(
      $compose_cmd exec -T postgres \
        psql -v ON_ERROR_STOP=1 -t -A \
        -U "$db_user" \
        -d "$db_name" \
        -c "SELECT COUNT(*) FROM public.${table_name};"
    )
    printf "  %-24s %s rows\n" "${table_name}:" "${row_count:-0}"
  done

  if [ "${#expected_views[@]}" -gt 0 ]; then
    echo ""
    echo "View row counts"
    echo "---------------"
    local view_name
    for view_name in "${expected_views[@]}"; do
      local view_count
      view_count=$(
        $compose_cmd exec -T postgres \
          psql -v ON_ERROR_STOP=1 -t -A \
          -U "$db_user" \
          -d "$db_name" \
          -c "SELECT COUNT(*) FROM public.${view_name};"
      )
      printf "  %-24s %s rows\n" "${view_name}:" "${view_count:-0}"
    done
  fi

  echo ""
  echo "Public schema inventory"
  echo "-----------------------"
  $compose_cmd exec -T postgres \
    psql -v ON_ERROR_STOP=1 \
    -U "$db_user" \
    -d "$db_name" \
    -c "
SELECT
  COUNT(*) FILTER (WHERE relkind = 'r') AS tables,
  COUNT(*) FILTER (WHERE relkind = 'v') AS views,
  COUNT(*) FILTER (WHERE relkind = 'i') AS indexes
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public';"
}
