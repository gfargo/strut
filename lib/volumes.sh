#!/usr/bin/env bash
# ==================================================
# volumes.sh — Volume management utilities
# ==================================================
# Provides functions for checking and managing data volumes.
# Does NOT perform migrations - use strut exec for manual migration.

# Note: Requires utils.sh to be sourced first for log functions

set -euo pipefail

# check_data_volume
#
# Checks whether the data volume is mounted at the expected mount point
# and prints disk usage if mounted.
#
# Requires env: DATA_VOLUME_MOUNT (default: /mnt/data)
# Returns: 0 if mounted, 1 if not
check_data_volume() {
  local mount_point="${DATA_VOLUME_MOUNT:-/mnt/data}"

  if mountpoint -q "$mount_point" 2>/dev/null; then
    log_success "Data volume mounted at $mount_point"
    df -h "$mount_point" | tail -1
    return 0
  else
    log_warn "Data volume NOT mounted at $mount_point"
    return 1
  fi
}

# verify_volume_config <stack_dir>
#
# Loads and displays the volume configuration from a stack's volume.conf file.
# Dynamically discovers and displays all path variables.
#
# Args:
#   stack_dir — Path to the stack directory (must contain volume.conf)
#
# Returns: 0 on success, 1 if volume.conf not found
# Side effects: Sources volume.conf into the current shell (sets env vars)
verify_volume_config() {
  local stack_dir="$1"
  local volume_conf="$stack_dir/volume.conf"

  if [[ ! -f "$volume_conf" ]]; then
    log_warn "No volume.conf found at $volume_conf"
    return 1
  fi

  source "$volume_conf"

  log_info "Volume Configuration:"
  echo "  Device: ${DATA_VOLUME_DEVICE:-not set}"
  echo "  Mount: ${DATA_VOLUME_MOUNT:-not set}"
  echo "  Size: ${DATA_VOLUME_SIZE:-not set}"
  echo ""
  echo "Paths:"

  # Read variable names from volume.conf and display matching path variables
  local var
  while IFS='=' read -r var _; do
    var="${var%%#*}"
    var="${var// /}"
    [[ -z "$var" ]] && continue
    case "$var" in
      DATA_VOLUME_DEVICE|DATA_VOLUME_MOUNT|DATA_VOLUME_SIZE)
        # Already displayed above
        ;;
      *_DATA_PATH|*_PATH|DATA_VOLUME_*)
        echo "  $var: ${!var:-not set}"
        ;;
    esac
  done < "$volume_conf"

  return 0
}

# volume_status
#
# Prints overall volume health: mount status, disk usage, and a breakdown
# of directory sizes under the mount point.
#
# Requires env: DATA_VOLUME_MOUNT (default: /mnt/data)
# Returns: 0 on success, 1 if volume not mounted
volume_status() {
  local mount_point="${DATA_VOLUME_MOUNT:-/mnt/data}"

  log_info "Volume Status"
  echo ""

  if ! check_data_volume; then
    log_error "Data volume not mounted"
    return 1
  fi

  echo ""
  log_info "Disk Usage:"
  df -h "$mount_point"

  echo ""
  log_info "Directory Structure:"
  if [[ -d "$mount_point" ]]; then
    du -sh "$mount_point"/* 2>/dev/null || echo "  (empty)"
  fi

  return 0
}

# init_volume_directories <stack_dir>
#
# Creates the directory tree required by stack services and sets ownership
# based on optional VOLUME_OWNERS mappings from volume.conf.
# Requires the data volume to already be mounted.
#
# Args:
#   stack_dir — Path to the stack directory (must contain volume.conf)
#
# volume.conf may define:
#   VOLUME_OWNERS — space-separated VAR_NAME=uid:gid mappings
#     e.g. VOLUME_OWNERS="DB_DATA_PATH=myuid:mygid SEARCH_DATA_PATH=myuid:mygid"
#
# Returns: 0 on success, 1 if volume.conf missing or volume not mounted
# Side effects: Creates directories and chowns them on the data volume
init_volume_directories() {
  local stack_dir="$1"
  local volume_conf="$stack_dir/volume.conf"

  if [[ ! -f "$volume_conf" ]]; then
    log_error "volume.conf not found at $volume_conf"
    return 1
  fi

  source "$volume_conf"

  local mount_point="${DATA_VOLUME_MOUNT:-/mnt/data}"

  if ! mountpoint -q "$mount_point" 2>/dev/null; then
    log_error "Data volume not mounted at $mount_point"
    log_info "Run volume initialization first"
    return 1
  fi

  log_info "Creating volume directory structure..."

  # Read variable names from volume.conf and create dirs for *_DATA_PATH and *_PATH
  local var dir
  while IFS='=' read -r var _; do
    # Strip whitespace and skip comments/empty lines
    var="${var%%#*}"
    var="${var// /}"
    [[ -z "$var" ]] && continue
    case "$var" in
      *_DATA_PATH|*_PATH)
        dir="${!var:-}"
        if [[ -n "$dir" && ! -d "$dir" ]]; then
          mkdir -p "$dir"
          log_success "Created: $dir"
        fi
        ;;
    esac
  done < "$volume_conf"

  # Apply ownership from VOLUME_OWNERS if set
  if [[ -n "${VOLUME_OWNERS:-}" ]]; then
    local mapping var_name uid_gid target_dir
    for mapping in $VOLUME_OWNERS; do
      var_name="${mapping%%=*}"
      uid_gid="${mapping#*=}"
      target_dir="${!var_name:-}"
      if [[ -n "$target_dir" && -d "$target_dir" ]]; then
        chown -R "$uid_gid" "$target_dir" 2>/dev/null || true  # may lack permissions on some hosts
      fi
    done
  fi

  log_success "Volume directories initialized"
  return 0
}

# export_volume_paths <stack_dir>
#
# Sources volume.conf from the given stack directory and dynamically exports
# all *_DATA_PATH, *_PATH, and DATA_VOLUME_* variables so they are available
# to docker-compose interpolation.
#
# Args:
#   stack_dir — Path to the stack directory (may contain volume.conf)
#
# Side effects: Exports all matching path variables into the environment
export_volume_paths() {
  local stack_dir="$1"
  local volume_conf="$stack_dir/volume.conf"

  if [[ -f "$volume_conf" ]]; then
    source "$volume_conf"

    # Read variable names from volume.conf and export matching patterns
    local var
    while IFS='=' read -r var _; do
      var="${var%%#*}"
      var="${var// /}"
      [[ -z "$var" ]] && continue
      case "$var" in
        *_DATA_PATH|*_PATH|DATA_VOLUME_*) export "${var?}" ;;
      esac
    done < "$volume_conf"
  fi
}
