#!/usr/bin/env bash
# ==================================================
# lib/migrate/ssh-helpers.sh — SSH connection helpers
# ==================================================

# Build SSH command with port and key
# Usage: build_ssh_cmd <vps_user> <vps_host> <ssh_port> <ssh_key>
set -euo pipefail

build_ssh_cmd() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$ssh_port" -k "$ssh_key")

  echo "ssh $ssh_opts $vps_user@$vps_host"
}

# Execute SSH command on VPS
# Usage: ssh_exec <vps_user> <vps_host> <ssh_port> <ssh_key> <command>
ssh_exec() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"
  shift 4
  local command="$*"

  local ssh_cmd
  ssh_cmd=$(build_ssh_cmd "$vps_user" "$vps_host" "$ssh_port" "$ssh_key")

  $ssh_cmd "$command"
}

# Build SCP command with port and key
# Usage: build_scp_cmd <vps_user> <vps_host> <ssh_port> <ssh_key>
build_scp_cmd() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  local scp_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
  [ -n "$ssh_port" ] && scp_opts="$scp_opts -P $ssh_port"
  [ -n "$ssh_key" ] && scp_opts="$scp_opts -i $ssh_key"

  echo "scp $scp_opts"
}

# Test SSH connectivity
# Usage: test_ssh_connection <vps_user> <vps_host> <ssh_port> <ssh_key>
# Returns: 0 if successful, 1 if failed
test_ssh_connection() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "echo 'ok'" &>/dev/null
}
