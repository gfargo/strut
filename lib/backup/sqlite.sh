#!/usr/bin/env bash
# ==================================================
# lib/backup/sqlite.sh — SQLite backup and restore
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Provides backup/restore for SQLite databases.
# Supports two modes:
#   1. Host-path mode (default): sqlite3 runs directly on VPS host
#   2. Docker-exec mode (BACKUP_SQLITE_USE_DOCKER=true): runs sqlite3
#      inside the container, then copies the backup out. Use this when
#      the DB lives in a Docker volume.
# Used by: Jitsi stack (transcripts.db in Docker volume)

# backup_sqlite <stack> <compose_cmd>
# Copies the SQLite database file from VPS to local backups.
# SQLite .backup command ensures a consistent snapshot even
# if the database is being written to.
set -euo pipefail

backup_sqlite() {
  local stack="$1"
  local compose_cmd="$2" # unused for SQLite but kept for interface consistency
  local backup_dir
  backup_dir=$(_backup_dir "$stack")
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local out="$backup_dir/sqlite-$timestamp.db"

  mkdir -p "$backup_dir"

  # Load SQLite path from backup.conf
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_conf="$cli_root/stacks/$stack/backup.conf"
  local sqlite_path="${BACKUP_SQLITE_PATH:-}"

  if [ -z "$sqlite_path" ] && [ -f "$backup_conf" ]; then
    sqlite_path=$(grep '^BACKUP_SQLITE_PATH=' "$backup_conf" | cut -d= -f2-)
  fi

  [ -n "$sqlite_path" ] || fail "BACKUP_SQLITE_PATH not set in backup.conf"

  # Load Docker-exec mode settings
  local use_docker="${BACKUP_SQLITE_USE_DOCKER:-}"
  local sqlite_container="${BACKUP_SQLITE_CONTAINER:-}"

  if [ -z "$use_docker" ] && [ -f "$backup_conf" ]; then
    use_docker=$(grep '^BACKUP_SQLITE_USE_DOCKER=' "$backup_conf" | cut -d= -f2-)
  fi
  if [ -z "$sqlite_container" ] && [ -f "$backup_conf" ]; then
    sqlite_container=$(grep '^BACKUP_SQLITE_CONTAINER=' "$backup_conf" | cut -d= -f2-)
  fi

  # Determine if this is a remote (VPS) or local backup
  local vps_host="${VPS_HOST:-}"

  if [ -n "$vps_host" ]; then
    _backup_sqlite_remote "$stack" "$sqlite_path" "$out" "$use_docker" "$sqlite_container"
  else
    _backup_sqlite_local "$sqlite_path" "$out"
  fi
}

# _backup_sqlite_remote <stack> <sqlite_path> <out> [use_docker] [container]
# Backs up a SQLite DB from a remote VPS via SSH.
# When use_docker=true, runs sqlite3 .backup inside the container
# and copies the result out via docker cp.
_backup_sqlite_remote() {
  local stack="$1"
  local sqlite_path="$2"
  local out="$3"
  local use_docker="${4:-false}"
  local sqlite_container="${5:-}"

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key")

  # Sudo prefix (some VPS hosts need sudo for file access / docker)
  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  log "Backing up SQLite (remote) → $out"

  local remote_tmp="/tmp/sqlite-backup-$$.db"

  if [ "$use_docker" = "true" ]; then
    # ── Docker-exec mode ──────────────────────────────────
    # DB lives inside a Docker volume; run sqlite3 .backup
    # inside the container, then docker cp the result out.
    [ -n "$sqlite_container" ] || fail "BACKUP_SQLITE_CONTAINER not set (required for docker mode)"

    log "Using docker exec mode (container: $sqlite_container)"

    # Run sqlite3 .backup inside the container
    # The backup goes to /tmp inside the container, then we docker cp it out
    ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}docker exec $sqlite_container sqlite3 '$sqlite_path' '.backup /tmp/backup.db'" \
      || {
        # Fallback: try cp if sqlite3 not available in container
        warn "sqlite3 .backup failed in container — trying file copy"
        ssh $ssh_opts "$vps_user@$vps_host" \
          "${_sudo}docker exec $sqlite_container cp '$sqlite_path' /tmp/backup.db" \
          || {
            error "SQLite backup failed in container"
            return 1
          }
      }

    # Copy from container to VPS host /tmp
    ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}docker cp $sqlite_container:/tmp/backup.db '$remote_tmp'" \
      || {
        error "docker cp failed"
        return 1
      }

    # Clean up inside container
    ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}docker exec $sqlite_container rm -f /tmp/backup.db" 2>/dev/null

  else
    # ── Host-path mode (original) ─────────────────────────
    # DB lives on the host filesystem; use sqlite3 directly.
    if ssh $ssh_opts "$vps_user@$vps_host" \
      "command -v sqlite3 >/dev/null 2>&1" 2>/dev/null; then
      ssh $ssh_opts "$vps_user@$vps_host" \
        "${_sudo}sqlite3 '$sqlite_path' '.backup $remote_tmp'" \
        || {
          error "SQLite .backup failed on VPS"
          return 1
        }
    else
      warn "sqlite3 not found on VPS — falling back to file copy"
      ssh $ssh_opts "$vps_user@$vps_host" \
        "${_sudo}cp '$sqlite_path' '$remote_tmp'" \
        || {
          error "SQLite copy failed on VPS"
          return 1
        }
    fi
  fi

  # Download
  rsync -avz -e "ssh $ssh_opts" \
    "$vps_user@$vps_host:$remote_tmp" "$out" \
    || {
      error "Failed to download SQLite backup"
      return 1
    }

  # Cleanup remote temp
  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}rm -f '$remote_tmp'" 2>/dev/null

  ok "SQLite backup saved: $out"
  create_backup_metadata "$stack" "$out" "sqlite" ""
}

# _backup_sqlite_local <sqlite_path> <out>
# Backs up a local SQLite database file.
_backup_sqlite_local() {
  local sqlite_path="$1"
  local out="$2"

  [ -f "$sqlite_path" ] || fail "SQLite database not found: $sqlite_path"

  log "Backing up SQLite (local) → $out"

  if command -v sqlite3 &>/dev/null; then
    sqlite3 "$sqlite_path" ".backup '$out'" \
      && ok "SQLite backup saved: $out" \
      || {
        error "SQLite .backup failed"
        return 1
      }
  else
    cp "$sqlite_path" "$out" \
      && ok "SQLite backup saved (file copy): $out" \
      || {
        error "SQLite copy failed"
        return 1
      }
  fi
}

# restore_sqlite <stack> <compose_cmd> <db_file> [target_env]
# Restores a SQLite database from a backup file.
restore_sqlite() {
  local stack="$1"
  local compose_cmd="$2" # unused but kept for interface consistency
  local db_file="$3"
  local target_env="${4:-}"

  [ -f "$db_file" ] || fail "SQLite backup file not found: $db_file"

  # Load config
  if [ -n "$target_env" ]; then
    local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    local target_env_file="$cli_root/.${target_env}.env"
    [ -f "$target_env_file" ] || fail "Target env file not found: $target_env_file"
    set -a
    source "$target_env_file"
    set +a
  fi

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_conf="$cli_root/stacks/$stack/backup.conf"
  local sqlite_path="${BACKUP_SQLITE_PATH:-}"

  if [ -z "$sqlite_path" ] && [ -f "$backup_conf" ]; then
    sqlite_path=$(grep '^BACKUP_SQLITE_PATH=' "$backup_conf" | cut -d= -f2-)
  fi

  [ -n "$sqlite_path" ] || fail "BACKUP_SQLITE_PATH not set in backup.conf"

  # Load Docker-exec mode settings
  local use_docker="${BACKUP_SQLITE_USE_DOCKER:-}"
  local sqlite_container="${BACKUP_SQLITE_CONTAINER:-}"

  if [ -z "$use_docker" ] && [ -f "$backup_conf" ]; then
    use_docker=$(grep '^BACKUP_SQLITE_USE_DOCKER=' "$backup_conf" | cut -d= -f2-)
  fi
  if [ -z "$sqlite_container" ] && [ -f "$backup_conf" ]; then
    sqlite_container=$(grep '^BACKUP_SQLITE_CONTAINER=' "$backup_conf" | cut -d= -f2-)
  fi

  warn "This will restore SQLite database at: $sqlite_path"
  confirm "Continue?" || {
    ok "Restore cancelled"
    return 0
  }

  local vps_host="${VPS_HOST:-}"

  if [ -n "$vps_host" ]; then
    _restore_sqlite_remote "$stack" "$db_file" "$sqlite_path" "$use_docker" "$sqlite_container"
  else
    _restore_sqlite_local "$db_file" "$sqlite_path"
  fi
}

# _restore_sqlite_remote <stack> <db_file> <sqlite_path> [use_docker] [container]
# Restores a SQLite DB to a remote VPS via SSH.
# When use_docker=true, uploads the file to the VPS, then uses
# docker cp to place it inside the container volume.
_restore_sqlite_remote() {
  local stack="$1"
  local db_file="$2"
  local sqlite_path="$3"
  local use_docker="${4:-false}"
  local sqlite_container="${5:-}"

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key")

  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  log "Restoring SQLite to VPS..."

  # Upload backup file to VPS /tmp
  local remote_tmp="/tmp/sqlite-restore-$$.db"
  rsync -avz -e "ssh $ssh_opts" \
    "$db_file" "$vps_user@$vps_host:$remote_tmp" \
    || {
      error "Failed to upload SQLite backup"
      return 1
    }

  if [ "$use_docker" = "true" ]; then
    # ── Docker mode ───────────────────────────────────
    # Copy the backup into the container, then move it into place.
    [ -n "$sqlite_container" ] || fail "BACKUP_SQLITE_CONTAINER not set (required for docker mode)"

    log "Using docker cp mode (container: $sqlite_container)"

    # Stop writes: pause the container briefly for a clean restore
    ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}docker stop $sqlite_container" 2>/dev/null

    # Copy backup file into the container
    ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}docker cp '$remote_tmp' $sqlite_container:'$sqlite_path'" \
      || {
        # Restart container even on failure
        ssh $ssh_opts "$vps_user@$vps_host" \
          "${_sudo}docker start $sqlite_container" 2>/dev/null
        error "docker cp restore failed"
        return 1
      }

    # Restart the container
    ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}docker start $sqlite_container" \
      || warn "Container restart failed — may need manual intervention"

  else
    # ── Host-path mode (original) ─────────────────────
    ssh $ssh_opts "$vps_user@$vps_host" \
      "${_sudo}cp '$remote_tmp' '$sqlite_path'" \
      || {
        error "SQLite restore failed"
        return 1
      }
  fi

  # Cleanup remote temp
  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}rm -f '$remote_tmp'" 2>/dev/null

  ok "SQLite restore complete"
}

# _restore_sqlite_local <db_file> <sqlite_path>
_restore_sqlite_local() {
  local db_file="$1"
  local sqlite_path="$2"

  log "Restoring SQLite locally..."
  cp "$db_file" "$sqlite_path" \
    && ok "SQLite restore complete" \
    || {
      error "SQLite restore failed"
      return 1
    }
}
