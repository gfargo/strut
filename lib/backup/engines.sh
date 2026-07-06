#!/usr/bin/env bash
# ==================================================
# lib/backup/engines.sh — Backup engine registry
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Single source of truth for the set of supported DB backup engines.
# Adding a 5th engine means adding one entry to BACKUP_ENGINES plus one
# `case` arm in each helper below — no other site should hardcode the
# postgres/neo4j/mysql/sqlite quadruple.
#
# Arbitrary-directory backups (e.g. a stack-specific "gdrive transcripts"
# tarball) are a stack-specific concern, not a generic DB engine — use the
# pre_backup/post_backup hook system for those instead.

set -euo pipefail

BACKUP_ENGINES=(postgres neo4j mysql sqlite)

# backup_engine_glob <engine>
# Echoes the backup filename glob for an engine (relative to the backup dir).
backup_engine_glob() {
  local engine="$1"
  case "$engine" in
    postgres) echo "postgres-*.sql" ;;
    neo4j)    echo "neo4j-*.dump" ;;
    mysql)    echo "mysql-*.sql" ;;
    sqlite)   echo "sqlite-*.db" ;;
    *) error "Unknown backup engine: $engine"; return 1 ;;
  esac
}

# backup_engine_ext <engine>
# Echoes the backup file extension for an engine.
backup_engine_ext() {
  local engine="$1"
  case "$engine" in
    postgres) echo "sql" ;;
    neo4j)    echo "dump" ;;
    mysql)    echo "sql" ;;
    sqlite)   echo "db" ;;
    *) error "Unknown backup engine: $engine"; return 1 ;;
  esac
}

# backup_engine_service_var <engine>
# Echoes the name of the backup.conf var holding the engine's configured
# compose service / container name.
backup_engine_service_var() {
  local engine="$1"
  case "$engine" in
    postgres) echo "BACKUP_POSTGRES_SERVICE" ;;
    neo4j)    echo "BACKUP_NEO4J_SERVICE" ;;
    mysql)    echo "BACKUP_MYSQL_SERVICE" ;;
    sqlite)   echo "BACKUP_SQLITE_CONTAINER" ;;
    *) error "Unknown backup engine: $engine"; return 1 ;;
  esac
}

# backup_engine_enabled <engine>
# Returns 0 if the engine's BACKUP_<ENGINE> flag in backup.conf is "true".
# Postgres defaults to enabled; the rest default to disabled — matching the
# defaults every call site already assumed before this registry existed.
backup_engine_enabled() {
  local engine="$1"
  case "$engine" in
    postgres) [ "${BACKUP_POSTGRES:-true}" = "true" ] ;;
    neo4j)    [ "${BACKUP_NEO4J:-false}" = "true" ] ;;
    mysql)    [ "${BACKUP_MYSQL:-false}" = "true" ] ;;
    sqlite)   [ "${BACKUP_SQLITE:-false}" = "true" ] ;;
    *) error "Unknown backup engine: $engine"; return 1 ;;
  esac
}

# backup_dump_fn <engine>
# Echoes the name of the function that creates a backup for this engine.
backup_dump_fn() {
  echo "backup_$1"
}

# backup_restore_fn <engine>
# Echoes the name of the function that restores a backup for this engine.
backup_restore_fn() {
  echo "restore_$1"
}

# backup_verify_fn <engine>
# Echoes the name of the function that verifies a backup for this engine.
backup_verify_fn() {
  echo "verify_${1}_backup"
}

# backup_engine_label <engine>
# Echoes the human-readable display label for an engine (for headers/dashboards).
backup_engine_label() {
  local engine="$1"
  case "$engine" in
    postgres) echo "PostgreSQL" ;;
    neo4j)    echo "Neo4j" ;;
    mysql)    echo "MySQL" ;;
    sqlite)   echo "SQLite" ;;
    *) error "Unknown backup engine: $engine"; return 1 ;;
  esac
}
