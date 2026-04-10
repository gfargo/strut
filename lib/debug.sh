#!/usr/bin/env bash
# ==================================================
# debug.sh — Interactive debugging for strut
# ==================================================
#
# Functions for debugging running containers:
# - debug_exec: Execute commands in containers
# - debug_shell: Interactive shell access
# - debug_port_forward: Port forwarding for remote debugging
# - debug_copy: File copying between local and containers
# - debug_snapshot: Container snapshots for offline analysis
# - debug_inspect_env: Inspect environment variables
# - debug_resource_usage: Real-time resource usage
#
# Usage:
#   source lib/debug.sh
#   debug_exec <stack> <service> <command> <env_file>
#   debug_shell <stack> <service> <env_file>
#   debug_port_forward <stack> <service> <local_port> <remote_port> <env_file>
#   debug_copy <stack> <service> <source> <dest> <env_file>
#   debug_snapshot <stack> <service> <env_file>

set -euo pipefail

# ── Helper Functions ──────────────────────────────────────────────────────────

# debug_get_container_name <stack> <service> <env_file>
#
# Resolves the Docker container name for a given service in a stack.
# Format: <stack>-<env_name>-<service>-1
#
# Args:
#   stack     — Stack name
#   service   — Compose service name
#   env_file  — Path to env file (used to extract env name)
debug_get_container_name() {
  local stack="$1"
  local service="$2"
  local env_file="$3"

  local env_name
  env_name=$(extract_env_name "$env_file")

  # Container naming format: <stack>-<env>-<service>-1
  local container_name="${stack}-${env_name}-${service}-1"

  echo "$container_name"
}

# debug_check_container_running <container_name>
#
# Verifies a Docker container is currently running. Exits with fail if not.
#
# Args:
#   container_name — Full Docker container name
# Returns: 0 if running, exits via fail otherwise
debug_check_container_running() {
  local container_name="$1"

  if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    fail "Container not running: $container_name"
  fi
}

# debug_is_vps_env <env_file>
#
# Checks whether the given env file targets a remote VPS (has VPS_HOST set).
#
# Args:
#   env_file — Path to env file
# Returns: 0 if VPS_HOST is set, 1 otherwise
debug_is_vps_env() {
  local env_file="$1"

  if [ -f "$env_file" ]; then
    set -a; source "$env_file"; set +a
    [ -n "${VPS_HOST:-}" ]
  else
    return 1
  fi
}

# debug_vps_exec <env_file> <command>
#
# Executes a shell command on the remote VPS via SSH. Automatically prefixes
# docker commands with sudo when VPS_SUDO=true.
#
# Args:
#   env_file — Path to env file (must contain VPS_HOST)
#   command  — Shell command to execute remotely
# Requires env: VPS_HOST, VPS_USER, VPS_SSH_KEY (via env_file)
debug_vps_exec() {
  local env_file="$1"
  local cmd="$2"

  set -a; source "$env_file"; set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -k "$vps_ssh_key")

  # Prefix docker commands with sudo when VPS_SUDO=true
  local sudo_prefix
  sudo_prefix="$(vps_sudo_prefix)"
  if [ -n "$sudo_prefix" ] && [[ "$cmd" == docker* ]]; then
    cmd="${sudo_prefix}${cmd}"
  fi

  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "$cmd"
}

# ── Core Debug Functions ──────────────────────────────────────────────────────

# debug_exec <stack> <service> <command> <env_file>
#
# Executes a one-off command inside a running container. Routes through
# VPS SSH or local Docker depending on the env file.
#
# Args:
#   stack    — Stack name
#   service  — Compose service name
#   command  — Command to execute in the container
#   env_file — Path to env file
debug_exec() {
  local stack="$1"
  local service="$2"
  local command="$3"
  local env_file="$4"

  local container_name
  container_name=$(debug_get_container_name "$stack" "$service" "$env_file")

  log "Executing command in $container_name: $command"

  if debug_is_vps_env "$env_file"; then
    # Execute on VPS
    debug_vps_exec "$env_file" "docker exec $container_name $command"
  else
    # Execute locally
    debug_check_container_running "$container_name"
    docker exec "$container_name" sh -c "$command"
  fi
}

# debug_shell <stack> <service> <env_file>
#
# Opens an interactive shell (sh) inside a running container. Allocates a TTY
# for VPS connections.
#
# Args:
#   stack    — Stack name
#   service  — Compose service name
#   env_file — Path to env file
# Requires env: VPS_HOST, VPS_USER, VPS_SSH_KEY (via env_file, if VPS)
# Side effects: Opens interactive terminal session
debug_shell() {
  local stack="$1"
  local service="$2"
  local env_file="$3"

  local container_name
  container_name=$(debug_get_container_name "$stack" "$service" "$env_file")

  log "Opening interactive shell in $container_name"

  if debug_is_vps_env "$env_file"; then
    # Interactive shell on VPS
    set -a; source "$env_file"; set +a
    local vps_host="${VPS_HOST:-}"
    local vps_user="${VPS_USER:-ubuntu}"
    local vps_ssh_key="${VPS_SSH_KEY:-}"

    [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

    local ssh_opts
    ssh_opts=$(build_ssh_opts -k "$vps_ssh_key" --tty)

    # Use SSH with TTY allocation for interactive session
    # shellcheck disable=SC2029
    ssh $ssh_opts "$vps_user@$vps_host" "$(vps_sudo_prefix)docker exec -it $container_name sh"
  else
    # Interactive shell locally
    debug_check_container_running "$container_name"
    docker exec -it "$container_name" sh
  fi
}

# debug_port_forward <stack> <service> <local_port> <remote_port> <env_file>
#
# Sets up port forwarding from localhost to a container port. For VPS envs,
# creates an SSH tunnel. For local envs, shows existing docker port mappings.
#
# Args:
#   stack       — Stack name
#   service     — Compose service name
#   local_port  — Local port to bind
#   remote_port — Container port to forward to
#   env_file    — Path to env file
# Requires env: VPS_HOST, VPS_USER, VPS_SSH_KEY (via env_file, if VPS)
# Side effects: Creates SSH tunnel (blocks until Ctrl+C)
debug_port_forward() {
  local stack="$1"
  local service="$2"
  local local_port="$3"
  local remote_port="$4"
  local env_file="$5"

  local container_name
  container_name=$(debug_get_container_name "$stack" "$service" "$env_file")

  if debug_is_vps_env "$env_file"; then
    # Port forward from VPS to local
    set -a; source "$env_file"; set +a
    local vps_host="${VPS_HOST:-}"
    local vps_user="${VPS_USER:-ubuntu}"
    local vps_ssh_key="${VPS_SSH_KEY:-}"

    [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

    log "Port forwarding: localhost:$local_port -> $vps_host:$container_name:$remote_port"
    log "Press Ctrl+C to stop port forwarding"

    local ssh_opts
    ssh_opts=$(build_ssh_opts -k "$vps_ssh_key")

    # Create SSH tunnel: local -> VPS -> container
    # First get container IP on VPS
    local container_ip
    container_ip=$(debug_vps_exec "$env_file" "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $container_name")

    # Create SSH tunnel
    ssh $ssh_opts -L "$local_port:$container_ip:$remote_port" -N "$vps_user@$vps_host"
  else
    # Port forward locally (container port already exposed via docker-compose)
    log "For local containers, ports are already mapped in docker-compose.yml"
    log "Check docker-compose.yml for port mappings"
    docker port "$container_name"
  fi
}

# debug_copy <stack> <service> <source> <dest> <env_file>
#
# Copies files between the local filesystem and a container. Direction is
# inferred from the source path: paths containing ":" are treated as
# container paths. For VPS envs, uses a two-step copy via SSH.
#
# Args:
#   stack    — Stack name
#   service  — Compose service name
#   source   — Source path (prefix with "container:" for container paths)
#   dest     — Destination path
#   env_file — Path to env file
# Side effects: Copies files, creates/removes temp files on VPS
debug_copy() {
  local stack="$1"
  local service="$2"
  local source="$3"
  local dest="$4"
  local env_file="$5"

  local container_name
  container_name=$(debug_get_container_name "$stack" "$service" "$env_file")

  # Determine direction: local->container or container->local
  local direction
  if [[ "$source" == *":"* ]]; then
    direction="from-container"
    log "Copying from container to local: $source -> $dest"
  else
    direction="to-container"
    log "Copying from local to container: $source -> $dest"
  fi

  if debug_is_vps_env "$env_file"; then
    # Copy via VPS
    set -a; source "$env_file"; set +a
    local vps_host="${VPS_HOST:-}"
    local vps_user="${VPS_USER:-ubuntu}"
    local vps_ssh_key="${VPS_SSH_KEY:-}"

    [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

    local ssh_opts
    ssh_opts=$(build_ssh_opts -k "$vps_ssh_key")

    if [ "$direction" = "from-container" ]; then
      # Container -> VPS -> Local (two-step copy)
      local container_path="${source#*:}"
      local temp_file="/tmp/debug-copy-$$-$(basename "$container_path")"

      log "Step 1: Copying from container to VPS temp location"
      debug_vps_exec "$env_file" "docker cp $container_name:$container_path $temp_file"

      log "Step 2: Copying from VPS to local"
      scp $ssh_opts "$vps_user@$vps_host:$temp_file" "$dest"

      log "Cleaning up temp file on VPS"
      debug_vps_exec "$env_file" "rm -f $temp_file"
    else
      # Local -> VPS -> Container (two-step copy)
      local temp_file="/tmp/debug-copy-$$-$(basename "$source")"

      log "Step 1: Copying from local to VPS temp location"
      scp $ssh_opts "$source" "$vps_user@$vps_host:$temp_file"

      log "Step 2: Copying from VPS to container"
      debug_vps_exec "$env_file" "docker cp $temp_file $container_name:$dest"

      log "Cleaning up temp file on VPS"
      debug_vps_exec "$env_file" "rm -f $temp_file"
    fi
  else
    # Copy locally
    debug_check_container_running "$container_name"

    if [ "$direction" = "from-container" ]; then
      docker cp "$container_name:${source#*:}" "$dest"
    else
      docker cp "$source" "$container_name:$dest"
    fi
  fi

  ok "Copy completed successfully"
}

# debug_snapshot <stack> <service> <env_file>
#
# Creates a Docker image snapshot (docker commit) of a running container
# for offline analysis.
#
# Args:
#   stack    — Stack name
#   service  — Compose service name
#   env_file — Path to env file
# Side effects: Creates a new Docker image named <stack>-<service>-snapshot-<timestamp>
debug_snapshot() {
  local stack="$1"
  local service="$2"
  local env_file="$3"

  local container_name
  container_name=$(debug_get_container_name "$stack" "$service" "$env_file")

  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local snapshot_name="${stack}-${service}-snapshot-${timestamp}"

  log "Creating snapshot of $container_name -> $snapshot_name"

  if debug_is_vps_env "$env_file"; then
    # Create snapshot on VPS
    debug_vps_exec "$env_file" "docker commit $container_name $snapshot_name"

    log "Snapshot created on VPS: $snapshot_name"
    log "To download snapshot:"
    log "  1. Save: docker save $snapshot_name -o /tmp/$snapshot_name.tar"
    log "  2. Download: scp vps:/tmp/$snapshot_name.tar ./"
    log "  3. Load locally: docker load -i $snapshot_name.tar"
  else
    # Create snapshot locally
    debug_check_container_running "$container_name"
    docker commit "$container_name" "$snapshot_name"

    ok "Snapshot created: $snapshot_name"
    log "To save snapshot to file: docker save $snapshot_name -o $snapshot_name.tar"
  fi
}

# debug_inspect_env <stack> <service> <env_file>
#
# Prints all environment variables inside a running container, sorted.
#
# Args:
#   stack    — Stack name
#   service  — Compose service name
#   env_file — Path to env file
debug_inspect_env() {
  local stack="$1"
  local service="$2"
  local env_file="$3"

  local container_name
  container_name=$(debug_get_container_name "$stack" "$service" "$env_file")

  log "Environment variables in $container_name:"
  echo ""

  if debug_is_vps_env "$env_file"; then
    debug_vps_exec "$env_file" "docker exec $container_name env | sort"
  else
    debug_check_container_running "$container_name"
    docker exec "$container_name" env | sort
  fi
}

# debug_resource_usage <stack> <service> <env_file>
#
# Streams real-time CPU/memory/network stats for a container via docker stats.
# Blocks until Ctrl+C.
#
# Args:
#   stack    — Stack name
#   service  — Compose service name
#   env_file — Path to env file
# Side effects: Streams output to stdout (blocks)
debug_resource_usage() {
  local stack="$1"
  local service="$2"
  local env_file="$3"

  local container_name
  container_name=$(debug_get_container_name "$stack" "$service" "$env_file")

  log "Real-time resource usage for $container_name:"
  log "Press Ctrl+C to stop"
  echo ""

  if debug_is_vps_env "$env_file"; then
    # Stream stats from VPS
    set -a; source "$env_file"; set +a
    local vps_host="${VPS_HOST:-}"
    local vps_user="${VPS_USER:-ubuntu}"
    local vps_ssh_key="${VPS_SSH_KEY:-}"

    [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

    local ssh_opts
    ssh_opts=$(build_ssh_opts -k "$vps_ssh_key" --tty)

    # shellcheck disable=SC2029
    ssh $ssh_opts "$vps_user@$vps_host" "$(vps_sudo_prefix)docker stats $container_name"
  else
    debug_check_container_running "$container_name"
    docker stats "$container_name"
  fi
}
