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

# ── JSON helpers ──────────────────────────────────────────────────────────────

# json_escape <string>
#
# Escapes a string for safe embedding inside a hand-built JSON string value.
# Order matters: backslashes must be escaped FIRST, then quotes, then control
# characters — otherwise the backslashes just inserted for \n/\r/\t would
# themselves get doubled by a later backslash pass.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  echo "$s"
}

# sed_escape_replacement <string>
#
# Escapes a string for safe interpolation into the replacement side of a
# `sed s/.../.../ ` expression delimited by `/`. Order matters: backslashes
# must be escaped FIRST, then the delimiter, then `&` — otherwise the
# backslashes just inserted for `/` and `&` would themselves get doubled by
# a later pass. Without this, a value containing `/`, `&`, or `\` (e.g. an
# org name like "ac/me & co") corrupts the sed expression or silently
# clobbers matched text.
sed_escape_replacement() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\//\\/}"
  s="${s//&/\\&}"
  printf '%s' "$s"
}

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
#   local api_port="${API_PORT:-8000}"
load_services_conf() {
  local stack_dir="$1"
  local conf="$stack_dir/services.conf"
  if [ -f "$conf" ]; then
    safe_source_config "$conf" || return 1
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
  usage=$(_get_mem_percent)
  if [ -z "$usage" ] || [ "$usage" = "0" ]; then
    warn "Memory: unable to determine usage (skipped)"
    return 0
  fi
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

# _get_mem_percent — portable memory usage percentage (Linux + macOS)
_get_mem_percent() {
  if command -v free >/dev/null 2>&1; then
    free | awk 'NR==2 {printf "%.0f", $3/$2 * 100}'
  elif [ "$(uname)" = "Darwin" ]; then
    # macOS: use vm_stat + sysctl
    local page_size total_pages pages_free pages_active pages_speculative pages_wired
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
    total_pages=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / page_size ))
    # vm_stat gives counts in pages
    local vmstat
    vmstat=$(vm_stat 2>/dev/null) || { echo "0"; return; }
    pages_free=$(echo "$vmstat" | awk '/Pages free:/{gsub(/\./,"",$3); print $3}')
    pages_active=$(echo "$vmstat" | awk '/Pages active:/{gsub(/\./,"",$3); print $3}')
    pages_speculative=$(echo "$vmstat" | awk '/Pages speculative:/{gsub(/\./,"",$3); print $3}')
    pages_wired=$(echo "$vmstat" | awk '/Pages wired down:/{gsub(/\./,"",$4); print $4}')
    local used=$(( (pages_active + pages_wired + pages_speculative) ))
    if [ "$total_pages" -gt 0 ] 2>/dev/null; then
      echo $(( used * 100 / total_pages ))
    else
      echo "0"
    fi
  else
    echo "0"
  fi
}

# portable_timeout <seconds> <command...>
# Portable replacement for GNU timeout. Uses timeout if available,
# falls back to gtimeout (Homebrew coreutils), then a backgrounded
# process with kill.
portable_timeout() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    # Pure-bash fallback: run in background, kill after timeout
    "$@" &
    local pid=$!
    (sleep "$seconds" && kill -TERM "$pid" 2>/dev/null) &
    local watcher=$!
    if wait "$pid" 2>/dev/null; then
      kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
      return 0
    else
      local rc=$?
      kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
      return $rc
    fi
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
# Returns 0 if the current machine appears to be the VPS target.
# Checks: hostname match, hostname.local match, and local IP match.
# Requires VPS_HOST to be set in the environment.
is_running_on_vps() {
  local vps_host="${VPS_HOST:-}"
  [ -n "$vps_host" ] || return 1  # silent check — no VPS_HOST means not on VPS

  # Check if VPS_HOST matches the current hostname (with or without .local)
  local current_hostname
  current_hostname=$(hostname 2>/dev/null || echo "")
  if [ -n "$current_hostname" ]; then
    [[ "$current_hostname" == "$vps_host" ]] && return 0
    [[ "${current_hostname}.local" == "$vps_host" ]] && return 0
    # Also handle case where VPS_HOST has .local but hostname doesn't
    [[ "$current_hostname" == "${vps_host%.local}" ]] && return 0
  fi

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

# resolve_deploy_dir
#
# Echoes the canonical VPS deploy directory. All local code that constructs
# remote paths should call this rather than inlining ${VPS_DEPLOY_DIR:-...}.
#
# Resolution order:
#   1. $VPS_DEPLOY_DIR (explicit config, highest priority)
#   2. /home/$VPS_USER/strut (derived from VPS_USER)
#   3. /home/ubuntu/strut (default when VPS_USER is unset)
#
# The caller must source the env file BEFORE calling this so VPS_USER and
# VPS_DEPLOY_DIR are populated.
resolve_deploy_dir() {
  echo "${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut}"
}

# require_cmd <cmd> [install-hint]
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  command -v "$cmd" &>/dev/null || fail "$cmd not found${hint:+. $hint}"
}

# confirm <prompt> — returns 0 if user types y/yes, 1 otherwise
#
# Auto-yes paths (never blocks the caller):
#   STRUT_YES=1  — set by --yes/-y or environment; returns 0 without prompting
#   stdin not a TTY — returns 1 without prompting (fail-safe; caller sees "no")
#
# The stdin-TTY check prevents CI hangs when a script pipes into strut. Callers
# that need "yes" in that case must set STRUT_YES=1 explicitly.
confirm() {
  local prompt="${1:-Continue?}"
  if [ "${STRUT_YES:-}" = "1" ] || [ "${STRUT_YES:-}" = "true" ]; then
    log "$prompt [auto-yes: STRUT_YES=1]"
    return 0
  fi
  if [ ! -t 0 ]; then
    warn "$prompt — declining (no TTY; set STRUT_YES=1 to auto-approve)"
    return 1
  fi
  local answer
  read -r -p "$(echo -e "${YELLOW}${prompt}${NC} [y/N] ")" answer
  [[ "$answer" =~ ^[Yy](es)?$ ]]
}

# read_or_fail <var_name> <prompt> [--secret]
#
# Prompt for a value interactively, or fail with a clear error when
# non-interactive. Use this instead of a bare `read -p` for values (URLs,
# tokens, emails) that don't have a boolean answer. Callers should first
# check for a value from a --flag, and only call read_or_fail as a fallback.
#
#   --secret  — do not echo characters as they're typed (read -s)
read_or_fail() {
  local var_name="$1"
  local prompt="$2"
  local secret_flag=""
  [ "${3:-}" = "--secret" ] && secret_flag="-s"
  if [ ! -t 0 ]; then
    fail "$prompt — no value provided and stdin is not a TTY (set the flag or run interactively)"
  fi
  # shellcheck disable=SC2229  # intentional: assign into var named by $var_name
  read -r $secret_flag -p "$prompt" "$var_name"
  [ -n "$secret_flag" ] && echo  # newline after silent read
}

# ── SSH helpers ───────────────────────────────────────────────────────────────

# ssh_mux_control_path — emit the ssh ControlPath template used by this process
#
# Returns a per-pid, per-connection template path. ssh substitutes the tokens at
# connect time. We use %C (a fixed-length SHA1 hash of %l%h%p%r) instead of the
# verbose %r@%h:%p pattern, which prevents exceeding the ~104-char sun_path
# limit on macOS where $TMPDIR is already ~49 chars long.
#
# The directory defaults to /tmp (short, writable) rather than $TMPDIR to keep
# the total socket path well under the BSD/macOS limit. Override with
# STRUT_SSH_CONTROL_DIR for tests or custom setups.
ssh_mux_control_path() {
  local dir="${STRUT_SSH_CONTROL_DIR:-/tmp}"
  # Strip trailing slash for clean concatenation
  dir="${dir%/}"
  echo "$dir/strut-mux-$$-%C"
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
# Best-effort: we scan for control sockets matching our pid prefix and ask ssh
# to exit each master. Called from the strut entrypoint's EXIT trap.
# Also GCs orphaned sockets from crashed strut processes.
ssh_mux_cleanup() {
  ssh_mux_enabled || return 0
  local dir="${STRUT_SSH_CONTROL_DIR:-/tmp}"
  dir="${dir%/}"
  local sock
  # Sockets are named strut-mux-<pid>-<hash> (the %C expansion)
  for sock in "$dir"/strut-mux-"$$"-*; do
    [ -S "$sock" ] || continue
    ssh -O exit -o ControlPath="$sock" "placeholder" >/dev/null 2>&1 || true
    rm -f "$sock" 2>/dev/null || true
  done

  # GC: remove orphaned sockets from crashed processes (best-effort)
  _ssh_mux_gc "$dir"
}

# _ssh_mux_gc <dir> — remove strut mux sockets whose owning PID is dead
#
# Called during cleanup. Scans for all strut-mux-* sockets and removes those
# whose PID prefix is no longer alive. Silent on permission errors.
_ssh_mux_gc() {
  local dir="$1"
  local sock pid
  for sock in "$dir"/strut-mux-*; do
    [ -S "$sock" ] || continue
    # Extract PID from filename: strut-mux-<pid>-<hash>
    local basename="${sock##*/}"
    pid="${basename#strut-mux-}"
    pid="${pid%%-*}"
    # Skip our own PID (already handled above) and non-numeric
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [ "$pid" = "$$" ] && continue
    # If the owning PID is dead, remove the orphaned socket
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$sock" 2>/dev/null || true
    fi
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
  if [[ -n "$ssh_key" ]]; then
    # Reject key paths with spaces — SSH -i with unquoted word-split opts can't handle them
    if [[ "$ssh_key" == *" "* ]]; then
      echo "ERROR: SSH key path contains spaces: $ssh_key" >&2
      echo "ERROR: Rename or symlink the key to a path without spaces." >&2
      return 1
    fi
    opts="$opts -o IdentitiesOnly=yes -i $ssh_key"
  fi

  if [[ "$no_mux" != true ]] && ssh_mux_enabled; then
    local ctl_path
    ctl_path=$(ssh_mux_control_path)
    # ControlPath value is safe — ssh_mux_control_path uses /tmp + fixed-length names
    opts="$opts -o ControlMaster=auto -o ControlPath=$ctl_path -o ControlPersist=60s"
  fi

  echo "$opts"
}

# ── Env file validation ──────────────────────────────────────────────────────

# _env_not_found_hint <env_file>
#
# Echoes contextual hint lines when an env file is missing:
#   - if the name matches a topology host alias, suggests --host <name>
#   - lists available .*.env files in the same directory
_env_not_found_hint() {
  local env_file="$1"
  local env_name env_dir hint="" available="" f base name
  env_name=$(extract_env_name "$env_file")
  env_dir="$(dirname "$env_file")"

  if declare -f topology_is_host_alias &>/dev/null && topology_is_host_alias "$env_name"; then
    hint="  '$env_name' is a host alias in strut.conf — did you mean: --host $env_name"
  fi

  for f in "$env_dir"/.*.env; do
    [ -f "$f" ] || continue
    base="${f##*/}"; name="${base#.}"; name="${name%.env}"
    available="${available:+$available }$name"
  done
  [ -n "$available" ] && hint="${hint:+$hint
}  Available envs: $available"

  [ -n "$hint" ] && echo "$hint"
  return 0
}

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
  if [ ! -f "$env_file" ]; then
    local hint msg
    hint=$(_env_not_found_hint "$env_file")
    msg="Env file not found: $env_file"
    [ -n "$hint" ] && msg="$msg
$hint"
    fail "$msg"
  fi
  # Preserve connection vars already resolved by the dispatcher (topology
  # [stacks] mapping or an explicit --host override) so a global VPS_* defined
  # in the env file can't clobber the intended target when we re-source. (LA-223)
  local _vh="${VPS_HOST:-}" _vu="${VPS_USER:-}" _vp="${VPS_PORT:-}" _vk="${VPS_SSH_KEY:-}" _vd="${VPS_DEPLOY_DIR:-}"
  set -a; source "$env_file"; set +a
  [ -n "$_vh" ] && export VPS_HOST="$_vh"
  [ -n "$_vu" ] && export VPS_USER="$_vu"
  [ -n "$_vp" ] && export VPS_PORT="$_vp"
  [ -n "$_vk" ] && export VPS_SSH_KEY="$_vk"
  [ -n "$_vd" ] && export VPS_DEPLOY_DIR="$_vd"
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      fail "Required variable '$var' is empty or missing in $env_file"
    fi
  done
}

# deploy_prepare <stack> <stack_dir> <compose_file> <env_file>
#
# Shared preamble for deploy_stack and bg_deploy_stack: existence checks,
# env-file-missing hint, env sourcing/validation, volume path export, and
# per-stack required_vars validation.
deploy_prepare() {
  local stack="$1" stack_dir="$2" compose_file="$3" env_file="$4"

  [ -d "$stack_dir" ]    || fail "Stack not found: $stack (looked in $stack_dir)"
  [ -f "$compose_file" ] || fail "Compose file not found: $compose_file"
  if [ ! -f "$env_file" ]; then
    local _hint _msg
    _hint=$(_env_not_found_hint "$env_file")
    _msg="Env file not found: $env_file"
    [ -n "$_hint" ] && _msg="$_msg
$_hint"
    fail "$_msg"
  fi

  validate_env_file "$env_file"
  export_volume_paths "$stack_dir"

  local required_vars_file="$stack_dir/required_vars"
  if [ -f "$required_vars_file" ]; then
    local var val
    while IFS= read -r var || [ -n "$var" ]; do
      [ -z "$var" ] && continue
      # Validate var name to prevent injection — only allow valid identifiers
      if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        fail "Invalid variable name in required_vars: '$var'"
      fi
      # Safe indirect expansion (no eval)
      val="${!var:-}"
      [ -n "$val" ] || fail "Missing required env var: $var (check $env_file)"
    done < "$required_vars_file"
  fi
}

# deploy_run_pre_deploy_validation <stack> <stack_dir> <env_file> <env_name> [compose_cmd]
#
# Shared pre-deploy validation block for deploy_stack and bg_deploy_stack:
# --skip-validation / PRE_DEPLOY_VALIDATE gating, cmd_validate, optional
# compose-syntax check (only when compose_cmd is passed), and the pre_deploy
# hook.
deploy_run_pre_deploy_validation() {
  local stack="$1" stack_dir="$2" env_file="$3" env_name="$4" compose_cmd="${5:-}"

  if [ "${SKIP_VALIDATION:-false}" = "true" ]; then
    warn "Pre-deploy validation skipped (--skip-validation)"
    return 0
  fi
  [ "${PRE_DEPLOY_VALIDATE:-true}" = "true" ] || return 0

  local strut_home="${STRUT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  source "$strut_home/lib/cmd_validate.sh"
  export CMD_STACK="$stack" CMD_STACK_DIR="$stack_dir" CMD_ENV_FILE="$env_file" CMD_ENV_NAME="$env_name"
  cmd_validate 2>/dev/null \
    || fail "Pre-deploy validation failed — fix errors and retry: strut $stack validate --env $env_name"

  if [ -n "$compose_cmd" ]; then
    if $compose_cmd config --quiet 2>/dev/null; then
      ok "docker-compose.yml: syntax valid"
    else
      warn "docker-compose.yml: syntax check failed (may still work)"
    fi
  fi

  if [ "${PRE_DEPLOY_HOOKS:-true}" = "true" ]; then
    fire_hook pre_deploy "$stack_dir" || fail "pre_deploy hook failed — aborting deploy"
  fi
  ok "Pre-deploy validation passed"
}

# _validate_no_spaces <path> <label>
#
# Fails with a clear error if <path> contains spaces. Used by compose command
# builders and SSH helpers that rely on word-split invocation patterns.
_validate_no_spaces() {
  local path="$1" label="${2:-path}"
  if [[ "$path" == *" "* ]]; then
    fail "The $label path contains spaces: '$path'. strut requires paths without spaces."
  fi
  return 0
}

# ── Compose command builders ──────────────────────────────────────────────────

# resolve_compose_cmd <stack> <env_file> [services_profile] [project_override]
#
# Builds the canonical `docker compose` command string for a stack.
# Handles project naming, env file, compose file path, sudo prefix,
# and optional service profile. All compose command construction should
# go through this function to ensure consistent --project-name format.
#
# Project name resolution order:
#   1. project_override, if passed (e.g. blue-green color-suffixed name)
#   2. COMPOSE_PROJECT_NAME from env file (respects existing deployments)
#   3. Auto-generated: <stack>-<env_name> (avoids double-prefix)
#
# Requires: _docker_sudo() from lib/docker.sh (available at call time)
resolve_compose_cmd() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"
  local project_override="${4:-}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local compose_file="$cli_root/stacks/$stack/docker-compose.yml"

  # Validate paths don't contain spaces (word-split pattern can't handle them)
  _validate_no_spaces "$env_file" "env file" || return 1
  _validate_no_spaces "$compose_file" "compose file" || return 1

  local project_name="$project_override"

  if [ -z "$project_name" ]; then
    # If COMPOSE_PROJECT_NAME is explicitly set in the environment (sourced from
    # the env file by validate_env_file upstream), respect it. This allows strut
    # to manage existing deployments that use a custom project name.
    project_name="${COMPOSE_PROJECT_NAME:-}"
  fi

  if [ -z "$project_name" ]; then
    local env_name
    env_name=$(extract_env_name "$env_file")
    # Avoid double-prefixing: if env_name already starts with "<stack>-" (e.g.,
    # jitsi-prod for the jitsi stack), use it as-is; otherwise prepend stack name.
    if [[ "$env_name" == "${stack}-"* ]]; then
      project_name="$env_name"
    else
      project_name="${stack}-${env_name}"
    fi
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

  # Validate paths don't contain spaces (word-split pattern can't handle them)
  _validate_no_spaces "$compose_file" "compose file" || return 1
  [ -f "$env_local" ] && { _validate_no_spaces "$env_local" "env file" || return 1; }

  local cmd="docker compose -f $compose_file"
  [ -f "$env_local" ] && cmd="$cmd --env-file $env_local"
  [ -n "$services_profile" ] && cmd="$cmd --profile $services_profile"
  echo "$cmd"
}

# ── Reverse proxy ─────────────────────────────────────────────────────────────

# build_proxy_reload_cmd <compose_cmd> <proxy>
#
# Echoes the reload command for the given proxy type, scoped to compose_cmd.
# Returns 1 (no output) for an unrecognized proxy — callers decide whether
# that's a silent no-op or a warn.
build_proxy_reload_cmd() {
  local compose_cmd="$1" proxy="$2"
  case "$proxy" in
    nginx) echo "$compose_cmd exec -T nginx nginx -s reload" ;;
    caddy) echo "$compose_cmd exec -T caddy caddy reload --config /etc/caddy/Caddyfile" ;;
    *)     return 1 ;;
  esac
}

# ── Remote introspection helpers ─────────────────────────────────────────────

# should_dispatch_remote
#
# Returns 0 (true) when:
#   - VPS_HOST is non-empty (env/topology has a remote target), AND
#   - We are NOT already running on that host (avoids SSH-to-self recursion).
#
# Use this before any read-only introspection command (status, logs, health)
# to decide whether to SSH to the remote or run locally.
should_dispatch_remote() {
  [ -n "${VPS_HOST:-}" ] || return 1
  if is_running_on_vps; then
    return 1
  fi
  return 0
}

# run_remote_strut <stack> <env_name> <remote_cmd_args>
#
# Executes  ./strut <stack> <remote_cmd_args> --env <env_name>  on the VPS
# over SSH, reusing the same connection variables (_stop_remote uses).
#
# Variables read from the environment (set by validate_env_file upstream):
#   VPS_HOST, VPS_USER (default: ubuntu), VPS_SSH_KEY, VPS_PORT (default: 22)
#   VPS_DEPLOY_DIR (default: /home/$vps_user/strut)
#
# Extra build_ssh_opts flags can be passed after the three required args:
#   run_remote_strut "$stack" "$env_name" "status" --tty --keepalive
#
# Honours DRY_RUN: prints the plan but does not execute.
run_remote_strut() {
  local stack="$1"
  local env_name="$2"
  local remote_cmd_args="$3"
  shift 3
  # Remaining args are extra build_ssh_opts flags (e.g. --tty --keepalive)
  local extra_ssh_flags=("$@")

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch "${extra_ssh_flags[@]+"${extra_ssh_flags[@]}"}")

  if [ "${DRY_RUN:-}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for remote ${remote_cmd_args%% *}:${NC}"
    run_cmd "Run on VPS" ssh "$vps_user@$vps_host" \
      "cd $deploy_dir && ./strut $stack $remote_cmd_args --env ${env_name:-prod}"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Suppress progress log when JSON output is requested so the stream is clean.
  if [ -z "${CMD_JSON:-}" ]; then
    log "Running '$remote_cmd_args' for stack '$stack' on $vps_user@$vps_host..." >&2
  fi

  # shellcheck disable=SC2029,SC2086
  ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    cd '$deploy_dir'
    ./strut $stack $remote_cmd_args --env ${env_name:-prod}
  " || fail "Remote command failed — check VPS_HOST and SSH access"
}

# ── Subcommand validation ─────────────────────────────────────────────────────

# ── Cron job helpers ──────────────────────────────────────────────────────────

# resolve_strut_binary
#
# Echoes the absolute path to the strut engine entrypoint. Cron jobs must
# invoke this instead of bare `strut` — cron's default PATH (/usr/bin:/bin)
# doesn't include wherever `strut` is installed, so a bare `strut` cron line
# fails with "command not found" before anything runs. STRUT_HOME (exported
# by the entrypoint) is the correct anchor — NOT CLI_ROOT, which at runtime
# is the user's project root, not the engine root.
resolve_strut_binary() {
  local strut_home="${STRUT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  echo "$strut_home/strut"
}

# ensure_cron_env_header
#
# Prepends PATH=/SHELL= lines to the crontab if not already present, so cron
# jobs run with the installing shell's PATH (docker, pg_dump, etc.) instead
# of cron's minimal default (/usr/bin:/bin). Idempotent — a no-op if the
# header already exists.
ensure_cron_env_header() {
  local existing
  existing="$(crontab -l 2>/dev/null || true)"

  if echo "$existing" | grep -q '^PATH='; then
    return 0
  fi

  {
    echo "PATH=$PATH"
    echo "SHELL=${SHELL:-/bin/bash}"
    if [ -n "$existing" ]; then
      echo "$existing"
    fi
  } | crontab -
}

# build_cron_job <name> <schedule> <command> <log_file>
#
# Builds one crontab line: creates the log directory, wraps <command> in a
# per-job flock (keyed on <name>) so overlapping runs no-op instead of
# racing, and redirects stdout/stderr to <log_file>. Echoes the finished
# line — callers still own the comment-line and dedup/replace logic.
build_cron_job() {
  local name="$1" schedule="$2" command="$3" log_file="$4"

  mkdir -p "$(dirname "$log_file")"

  local strut_home="${STRUT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local lock_dir="$strut_home/locks/cron"
  mkdir -p "$lock_dir"

  local slug
  slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-' | tr -s '-' | sed 's/^-//;s/-$//')
  local lock_file="$lock_dir/${slug}.lock"

  echo "$schedule flock -n $lock_file -c '$command >> $log_file 2>&1'"
}

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
