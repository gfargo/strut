#!/usr/bin/env bash
# ==================================================
# lib/backup/mysql.sh — MySQL backup and restore
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Provides backup/restore for MySQL databases via
# mysqldump inside Docker containers.
# Used by: DocSpace stack (MySQL 8.3.0)

# backup_mysql <stack> <compose_cmd>
# Creates a mysqldump and saves it locally.
set -euo pipefail

backup_mysql() {
  local stack="$1"
  local compose_cmd="$2"
  local backup_dir
  backup_dir=$(_backup_dir "$stack")
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local out="$backup_dir/mysql-$timestamp.sql"

  mkdir -p "$backup_dir"

  # Load MySQL connection details from stack env
  local mysql_container="${MYSQL_CONTAINER_NAME:-}"
  local mysql_db="${MYSQL_DATABASE:-}"
  # For backup, prefer root user when root password is available (needed for
  # --routines --triggers --events which require SUPER or elevated privileges)
  local mysql_user mysql_password
  if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
    mysql_user="root"
    mysql_password="$MYSQL_ROOT_PASSWORD"
  else
    mysql_user="${MYSQL_USER:-root}"
    mysql_password="${MYSQL_PASSWORD:-}"
  fi

  [ -n "$mysql_db" ] || fail "MYSQL_DATABASE not set in environment"

  # Sudo prefix for VPS hosts where deploy user needs sudo for Docker
  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  log "Backing up MySQL → $out"

  # If container name is set, use docker exec directly (more reliable for
  # stacks where the compose service name differs from the container name)
  if [ -n "$mysql_container" ]; then
    ${_sudo}docker exec "$mysql_container" \
      mysqldump -u "$mysql_user" --password="$mysql_password" \
      --single-transaction --routines --triggers --events \
      "$mysql_db" >"$out" 2>/dev/null \
      && ok "MySQL backup saved: $out" \
      && create_backup_metadata "$stack" "$out" "mysql" "" \
      || {
        error "MySQL backup failed"
        return 1
      }
  else
    # Fallback: use compose exec with the mysql service name
    ${_sudo}$compose_cmd exec -T onlyoffice-mysql-server \
      mysqldump -u "$mysql_user" --password="$mysql_password" \
      --single-transaction --routines --triggers --events \
      "$mysql_db" >"$out" 2>/dev/null \
      && ok "MySQL backup saved: $out" \
      && create_backup_metadata "$stack" "$out" "mysql" "" \
      || {
        error "MySQL backup failed"
        return 1
      }
  fi
}

# restore_mysql <stack> <compose_cmd> <sql_file> [target_env]
# Restores MySQL from a SQL dump file.
restore_mysql() {
  local stack="$1"
  local compose_cmd="$2"
  local sql_file="$3"
  local target_env="${4:-}"

  [ -f "$sql_file" ] || fail "SQL file not found: $sql_file"

  # If target_env is provided, rebuild compose_cmd for that environment
  if [ -n "$target_env" ]; then
    local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    local target_env_file="$cli_root/.${target_env}.env"
    [ -f "$target_env_file" ] || fail "Target env file not found: $target_env_file"

    log "Restoring to target environment: $target_env"
    compose_cmd=$(resolve_compose_cmd "$stack" "$target_env_file" "")
    set -a
    source "$target_env_file"
    set +a
  fi

  local mysql_container="${MYSQL_CONTAINER_NAME:-}"
  local mysql_db="${MYSQL_DATABASE:-}"
  local mysql_user mysql_password
  if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
    mysql_user="root"
    mysql_password="$MYSQL_ROOT_PASSWORD"
  else
    mysql_user="${MYSQL_USER:-root}"
    mysql_password="${MYSQL_PASSWORD:-}"
  fi

  [ -n "$mysql_db" ] || fail "MYSQL_DATABASE not set in environment"

  warn "This will restore MySQL from: $sql_file"
  confirm "Continue?" || {
    ok "Restore cancelled"
    return 0
  }

  # Sudo prefix for VPS hosts where deploy user needs sudo for Docker
  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  log "Restoring MySQL..."

  if [ -n "$mysql_container" ]; then
    ${_sudo}docker exec -i "$mysql_container" \
      mysql -u "$mysql_user" --password="$mysql_password" "$mysql_db" <"$sql_file" \
      && ok "MySQL restore complete" \
      || {
        error "MySQL restore failed"
        return 1
      }
  else
    ${_sudo}$compose_cmd exec -T onlyoffice-mysql-server \
      mysql -u "$mysql_user" --password="$mysql_password" "$mysql_db" <"$sql_file" \
      && ok "MySQL restore complete" \
      || {
        error "MySQL restore failed"
        return 1
      }
  fi
}
