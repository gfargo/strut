#!/usr/bin/env bash
# ==================================================
# lib/utils.sh — Common helpers, colors, log functions
# ==================================================
# Source this file first in all lib/*.sh modules:
#   source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

set -euo pipefail

# ── Error handling conventions ────────────────────────────────────────────────
# || fail "msg"                    — Fatal error, aborts script
# || { warn "msg"; return 1; }    — Non-fatal, caller decides
# || true  # <reason>             — Intentionally ignored (MUST have comment)
# Never use bare || return 1 without a message

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# ── Log helpers ───────────────────────────────────────────────────────────────
# When _error_context is set (e.g. "my-stack/prod/deploy") by the strut
# entrypoint, warn/fail/error prepend "[${_error_context}]" so CI logs and
# group deploys surface which stack/env/command triggered the message.
_error_prefix() {
  if [ -n "${_error_context:-}" ]; then
    printf '[%s] ' "$_error_context"
  fi
  return 0
}

log()  { echo -e "${BLUE}[strut]${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC}  $(_error_prefix)$1"; }
fail() { echo -e "${RED}✗${NC}  $(_error_prefix)$1" >&2; exit 1; }

# Like fail() but without exit — for non-fatal errors
error() { echo -e "${RED}✗${NC}  $(_error_prefix)$1" >&2; }

# ── Banner helpers ────────────────────────────────────────────────────────────

# print_banner <subtitle>
#
# Prints a boxed ASCII banner using BANNER_TEXT from config (default: strut).
# The subtitle describes the operation (e.g., "Multi-Service Deploy").
#
# Usage:
#   print_banner "Multi-Service Deploy"
#   print_banner "VPS Release Deploy"
print_banner() {
  local subtitle="${1:-}"
  local brand="${BANNER_TEXT:-strut}"
  local text="$brand  —  $subtitle"
  local text_len=${#text}
  # Box inner width: text + 6 padding chars (3 each side)
  local inner_width=$(( text_len + 6 ))
  local border
  border=$(printf '═%.0s' $(seq 1 "$inner_width"))
  echo -e "${BLUE}"
  echo "  ╔${border}╗"
  echo "  ║   ${text}   ║"
  echo "  ╚${border}╝"
  echo -e "${NC}"
}

# ── Dry-run support ──────────────────────────────────────────────────────────

# DRY_RUN — set to "true" by --dry-run flag in strut entrypoint
DRY_RUN="${DRY_RUN:-false}"
export DRY_RUN

# run_cmd <description> <command...>
#
# In dry-run mode, prints the command instead of executing it.
# In normal mode, logs the description and runs the command.
#
# Args:
#   description — human-readable label for the operation
#   command...  — the command and arguments to execute
#
# Returns: 0 in dry-run mode, command exit code otherwise
run_cmd() {
  local desc="$1"
  shift
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} $desc: $*"
    return 0
  else
    log "$desc"
    "$@"
  fi
}

# run_cmd_eval <description> <command_string>
#
# Like run_cmd but for commands that need shell evaluation (pipes, redirects).
# In dry-run mode, prints the command string instead of executing it.
#
# Args:
#   description    — human-readable label for the operation
#   command_string — the command string to eval
#
# Returns: 0 in dry-run mode, command exit code otherwise
run_cmd_eval() {
  local desc="$1"
  local cmd_str="$2"
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} $desc: $cmd_str"
    return 0
  else
    log "$desc"
    eval "$cmd_str"
  fi
}

# ── Stack services config ─────────────────────────────────────────────────────

# load_services_conf <stack_dir>
#
# Sources stacks/<stack>/services.conf if it exists, making port/path
# variables available to the caller. Safe to call even if the file is missing.
#
# Usage:
#   load_services_conf "$stack_dir"
#   local api_port="${CH_API_PORT:-8000}"
load_services_conf() {
  local stack_dir="$1"
  local conf="$stack_dir/services.conf"
  if [ -f "$conf" ]; then
    # shellcheck disable=SC1090
    source <(preprocess_config "$conf")
  fi
}

# ── Env name extraction ──────────────────────────────────────────────────────

# extract_env_name <env_file>
# Extracts the environment name from an env file path.
# Examples:
#   stacks/my-stack/.env.local → local
#   .prod.env → prod
#   .staging.env → staging
#   .env → prod (default)
extract_env_name() {
  local env_file="$1"
  local filename
  filename=$(basename "$env_file")

  if [[ "$filename" =~ ^\.env\.(.+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$filename" =~ ^\.(.+)\.env$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "prod"
  fi
}

# ── Resource checks ───────────────────────────────────────────────────────────

# check_disk [warn_pct] [fail_pct]
# Prints disk status; returns 0 (ok), 1 (warn), 2 (fail)
check_disk() {
  local warn_pct="${1:-80}"
  local fail_pct="${2:-90}"
  local usage
  usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
  if [ "$usage" -ge "$fail_pct" ]; then
    warn "Disk: ${usage}% used (critical — threshold ${fail_pct}%)"
    return 2
  elif [ "$usage" -ge "$warn_pct" ]; then
    warn "Disk: ${usage}% used (high — threshold ${warn_pct}%)"
    return 1
  else
    ok "Disk: ${usage}% used"
    return 0
  fi
}

# check_memory [warn_pct] [fail_pct]
check_memory() {
  local warn_pct="${1:-80}"
  local fail_pct="${2:-90}"
  local usage
  usage=$(free | awk 'NR==2 {printf "%.0f", $3/$2 * 100}')
  if [ "$usage" -ge "$fail_pct" ]; then
    warn "Memory: ${usage}% used (critical)"
    return 2
  elif [ "$usage" -ge "$warn_pct" ]; then
    warn "Memory: ${usage}% used (high)"
    return 1
  else
    ok "Memory: ${usage}% used"
    return 0
  fi
}

# check_cpu [warn_pct] [fail_pct]
check_cpu() {
  local warn_pct="${1:-70}"
  local fail_pct="${2:-90}"
  local load cpu_count load_percent
  load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
  cpu_count=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
  load_percent=$(echo "$load $cpu_count" | awk '{printf "%.0f", ($1/$2)*100}')
  if [ "$load_percent" -ge "$fail_pct" ]; then
    warn "CPU load: ${load} (${load_percent}% of capacity — critical)"
    return 2
  elif [ "$load_percent" -ge "$warn_pct" ]; then
    warn "CPU load: ${load} (${load_percent}% of capacity — high)"
    return 1
  else
    ok "CPU load: ${load} (${load_percent}% of capacity)"
    return 0
  fi
}

# ── VPS Docker helpers ────────────────────────────────────────────────────────

# vps_sudo_prefix
# Returns "sudo " if VPS_SUDO=true is set in the environment, empty string otherwise.
# Use this to prefix remote docker commands for hosts where the deploy user
# is not in the docker group (e.g. DocSpace VPS).
#
# Usage:
#   ssh $ssh_opts "$vps_user@$vps_host" "$(vps_sudo_prefix)docker ps"
#   ssh $ssh_opts "$vps_user@$vps_host" "$(vps_sudo_prefix)docker compose ..."
vps_sudo_prefix() {
  if [ "${VPS_SUDO:-false}" = "true" ]; then
    echo "sudo "
  fi
}

# ── Misc helpers ─────────────────────────────────────────────────────────────

# is_running_on_vps
# Returns 0 if the current machine appears to be the VPS (VPS_HOST matches a local IP).
# Requires VPS_HOST to be set in the environment.
is_running_on_vps() {
  local vps_host="${VPS_HOST:-}"
  [ -n "$vps_host" ] || return 1  # silent check — no VPS_HOST means not on VPS

  # Check if VPS_HOST matches any local IP address
  if command -v hostname &>/dev/null; then
    hostname -I 2>/dev/null | grep -qw "$vps_host" && return 0
  fi
  if command -v ip &>/dev/null; then
    ip addr 2>/dev/null | grep -qw "$vps_host" && return 0
  fi
  if command -v ifconfig &>/dev/null; then
    ifconfig 2>/dev/null | grep -qw "$vps_host" && return 0
  fi

  return 1
}

# require_cmd <cmd> [install-hint]
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  command -v "$cmd" &>/dev/null || fail "$cmd not found${hint:+. $hint}"
}

# confirm <prompt> — returns 0 if user types y/yes, 1 otherwise
confirm() {
  local prompt="${1:-Continue?}"
  read -r -p "$(echo -e "${YELLOW}${prompt}${NC} [y/N] ")" answer
  [[ "$answer" =~ ^[Yy](es)?$ ]]
}

# ── SSH helpers ───────────────────────────────────────────────────────────────

# ssh_mux_control_path — emit the ssh ControlPath template used by this process
#
# Returns a per-pid, per-user, per-host template path in TMPDIR (or /tmp). ssh
# substitutes %r/%h/%p at connect time, so one template covers every host
# reached during a single strut invocation.
#
# Respects STRUT_SSH_CONTROL_DIR to override the directory for tests.
ssh_mux_control_path() {
  local dir="${STRUT_SSH_CONTROL_DIR:-${TMPDIR:-/tmp}}"
  # Strip trailing slash for clean concatenation
  dir="${dir%/}"
  echo "$dir/strut-ssh-$$-%r@%h:%p"
}

# ssh_mux_enabled — 0 (true) if SSH connection multiplexing is enabled
#
# Opt out via STRUT_SSH_NO_MUX=1 (useful for debugging auth failures or for
# environments where the control socket path would be too long).
ssh_mux_enabled() {
  [ "${STRUT_SSH_NO_MUX:-0}" = "1" ] && return 1
  return 0
}

# ssh_mux_cleanup — close any master connections opened by this process
#
# Best-effort: we don't know which hosts were contacted, so we scan for control
# sockets matching our pid prefix and ask ssh to exit each master. Called from
# the strut entrypoint's EXIT trap.
ssh_mux_cleanup() {
  ssh_mux_enabled || return 0
  local dir="${STRUT_SSH_CONTROL_DIR:-${TMPDIR:-/tmp}}"
  dir="${dir%/}"
  local sock
  # Sockets are named strut-ssh-<pid>-<user>@<host>:<port>
  for sock in "$dir"/strut-ssh-"$$"-*; do
    [ -S "$sock" ] || continue
    # Extract user@host:port from filename suffix
    local suffix="${sock##*/strut-ssh-$$-}"
    ssh -O exit -o ControlPath="$sock" "$suffix" >/dev/null 2>&1 || true
    rm -f "$sock" 2>/dev/null || true
  done
}

# build_ssh_opts [options]
#
# Builds a standard SSH options string. All parameters are optional flags:
#   -p <port>       SSH port (omitted from opts if not provided)
#   -k <key>        SSH key path (omitted if empty)
#   -t <seconds>    ConnectTimeout (default: 10)
#   --batch         Add -o BatchMode=yes (default: off)
#   --tty           Add -t for interactive sessions
#   --keepalive     Add ServerAliveInterval=5, ServerAliveCountMax=2
#   --no-mux        Suppress ControlMaster options for this call
#
# ControlMaster/ControlPersist are appended by default so repeated SSH calls
# within a single strut command reuse one authenticated session. Opt out
# globally with STRUT_SSH_NO_MUX=1 or per-call with --no-mux.
#
# Echoes the options string. Caller captures via: ssh_opts=$(build_ssh_opts ...)
build_ssh_opts() {
  local port="" ssh_key="" timeout=10 batch=false tty=false keepalive=false no_mux=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p) port="$2"; shift 2 ;;
      -k) ssh_key="$2"; shift 2 ;;
      -t) timeout="$2"; shift 2 ;;
      --batch) batch=true; shift ;;
      --tty) tty=true; shift ;;
      --keepalive) keepalive=true; shift ;;
      --no-mux) no_mux=true; shift ;;
      *) shift ;;
    esac
  done

  local opts="-o StrictHostKeyChecking=no -o ConnectTimeout=$timeout"
  [[ -n "$port" ]] && opts="-p $port $opts"
  [[ "$batch" == true ]] && opts="$opts -o BatchMode=yes"
  [[ "$tty" == true ]] && opts="-t $opts"
  [[ "$keepalive" == true ]] && opts="$opts -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
  [[ -n "$ssh_key" ]] && opts="$opts -i $ssh_key"

  if [[ "$no_mux" != true ]] && ssh_mux_enabled; then
    local ctl_path
    ctl_path=$(ssh_mux_control_path)
    opts="$opts -o ControlMaster=auto -o ControlPath=$ctl_path -o ControlPersist=60s"
  fi

  echo "$opts"
}

# ── Env file validation ──────────────────────────────────────────────────────

# validate_env_file <env_file> <required_var1> [required_var2] ...
#
# Sources the env file and validates that all listed variables are non-empty.
# Fails with a clear message if the file is missing or a required var is empty.
#
# Usage:
#   validate_env_file "$ENV_FILE" VPS_HOST VPS_USER
#   validate_env_file "$ENV_FILE" VPS_HOST GH_PAT
validate_env_file() {
  local env_file="$1"; shift
  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a; source "$env_file"; set +a
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      fail "Required variable '$var' is empty or missing in $env_file"
    fi
  done
}

# ── Compose command builders ──────────────────────────────────────────────────

# resolve_compose_cmd <stack> <env_file> [services_profile]
#
# Builds the canonical `docker compose` command string for a stack.
# Handles project naming, env file, compose file path, sudo prefix,
# and optional service profile. All compose command construction should
# go through this function to ensure consistent --project-name format.
#
# Requires: _docker_sudo() from lib/docker.sh (available at call time)
resolve_compose_cmd() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local compose_file="$cli_root/stacks/$stack/docker-compose.yml"

  local env_name
  env_name=$(extract_env_name "$env_file")

  # Avoid double-prefixing: if env_name already starts with "<stack>-" (e.g.,
  # jitsi-prod for the jitsi stack), use it as-is; otherwise prepend stack name.
  local project_name
  if [[ "$env_name" == "${stack}-"* ]]; then
    project_name="$env_name"
  else
    project_name="${stack}-${env_name}"
  fi

  local cmd="$(_docker_sudo)docker compose --env-file $env_file --project-name $project_name -f $compose_file"
  [ -n "$services_profile" ] && cmd="$cmd --profile $services_profile"
  echo "$cmd"
}

# resolve_local_compose_cmd <stack> [services_profile]
#
# Builds a compose command for local development. Uses docker-compose.local.yml
# if present, falls back to docker-compose.yml. Attaches .env.local if present.
# No --project-name is set (Docker infers from directory).
resolve_local_compose_cmd() {
  local stack="$1"
  local services_profile="${2:-}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"

  local compose_file="$stack_dir/docker-compose.local.yml"
  [ -f "$compose_file" ] || compose_file="$stack_dir/docker-compose.yml"

  local env_local="$stack_dir/.env.local"

  local cmd="docker compose -f $compose_file"
  [ -f "$env_local" ] && cmd="$cmd --env-file $env_local"
  [ -n "$services_profile" ] && cmd="$cmd --profile $services_profile"
  echo "$cmd"
}

# ── Subcommand validation ─────────────────────────────────────────────────────

# validate_subcommand <value> <valid_cmd1> [valid_cmd2] ...
#
# Returns 0 if value matches one of the valid commands.
# On mismatch, prints an error listing valid options and returns 1.
#
# Usage:
#   validate_subcommand "$target" postgres neo4j mysql sqlite all || exit 1
validate_subcommand() {
  local value="$1"; shift
  local cmd
  for cmd in "$@"; do
    [ "$value" = "$cmd" ] && return 0
  done
  warn "Unknown subcommand: '$value'"
  echo "  Valid options: $*" >&2
  return 1
}
