#!/usr/bin/env bash
# ==================================================
# lib/config.sh — Project configuration discovery and loading
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Provides:
#   find_project_root   — walk-up search for strut.conf
#   load_strut_config   — source strut.conf and apply defaults
#   resolve_strut_home  — resolve real script directory (follows symlinks)
#   preprocess_config   — expand `include = <path>` directives in config files

set -euo pipefail

# ── Include directive ─────────────────────────────────────────────────────────

# State for cycle detection during a single preprocess_config invocation.
# Reset by preprocess_config; _preprocess_config appends to it recursively.
_CONFIG_INCLUDES_SEEN=()

# preprocess_config <file>
#
# Emits the contents of <file> to stdout with any `include = <path>` lines
# expanded inline. Base content appears at the directive's position, so any
# assignments *after* the include in the parent file override base values.
#
# Relative include paths resolve against the including file's directory.
# Circular includes abort via fail().
#
# Usage:
#   source <(preprocess_config "$PROJECT_ROOT/strut.conf")
#   while IFS= read -r line; do ... done < <(preprocess_config "$vars_file")
preprocess_config() {
  _CONFIG_INCLUDES_SEEN=()
  _preprocess_config "$1"
}

_preprocess_config() {
  local file="$1"
  local abs
  if [ ! -f "$file" ]; then
    fail "config include target not found: $file"
    return 1
  fi
  abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"

  local seen
  for seen in "${_CONFIG_INCLUDES_SEEN[@]+"${_CONFIG_INCLUDES_SEEN[@]}"}"; do
    if [ "$seen" = "$abs" ]; then
      fail "circular config include detected: $file"
      return 1
    fi
  done
  _CONFIG_INCLUDES_SEEN+=("$abs")

  local dir line inc_path
  dir=$(dirname "$abs")
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*include[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      inc_path="${BASH_REMATCH[1]}"
      # Trim trailing whitespace
      inc_path="${inc_path%"${inc_path##*[![:space:]]}"}"
      # Strip optional surrounding quotes
      inc_path="${inc_path#\"}"; inc_path="${inc_path%\"}"
      inc_path="${inc_path#\'}"; inc_path="${inc_path%\'}"
      [[ "$inc_path" != /* ]] && inc_path="$dir/$inc_path"
      _preprocess_config "$inc_path" || return 1
    else
      printf '%s\n' "$line"
    fi
  done < "$abs"
}

# find_project_root
#
# Walks up from $PWD looking for strut.conf. Sets PROJECT_ROOT when found.
# Returns 1 if not found (commands like `strut init` don't need it).
#
# Side effects: Sets and exports PROJECT_ROOT
find_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/strut.conf" ]; then
      PROJECT_ROOT="$dir"
      export PROJECT_ROOT
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  # Check root directory as well
  if [ -f "/strut.conf" ]; then
    PROJECT_ROOT="/"
    export PROJECT_ROOT
    return 0
  fi
  return 1
}

# load_strut_config
#
# Sources strut.conf from PROJECT_ROOT and applies defaults for any
# missing keys. Must be called after find_project_root succeeds.
#
# Defaults:
#   REGISTRY_TYPE=none
#   REGISTRY_HOST=  (empty)
#   DEFAULT_ORG=    (empty)
#   DEFAULT_BRANCH=main
#   BANNER_TEXT=strut
#
# Side effects: Exports all config variables
load_strut_config() {
  if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/strut.conf" ]; then
    # shellcheck disable=SC1090
    source <(preprocess_config "$PROJECT_ROOT/strut.conf")
  fi

  REGISTRY_TYPE="${REGISTRY_TYPE:-none}"
  REGISTRY_HOST="${REGISTRY_HOST:-}"
  DEFAULT_ORG="${DEFAULT_ORG:-}"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
  BANNER_TEXT="${BANNER_TEXT:-strut}"
  REVERSE_PROXY="${REVERSE_PROXY:-nginx}"
  PRE_DEPLOY_VALIDATE="${PRE_DEPLOY_VALIDATE:-true}"
  PRE_DEPLOY_HOOKS="${PRE_DEPLOY_HOOKS:-true}"

  export REGISTRY_TYPE REGISTRY_HOST DEFAULT_ORG DEFAULT_BRANCH BANNER_TEXT REVERSE_PROXY PRE_DEPLOY_VALIDATE PRE_DEPLOY_HOOKS

  # Validate REVERSE_PROXY
  case "$REVERSE_PROXY" in
    nginx|caddy) ;;
    *) fail "Invalid REVERSE_PROXY='$REVERSE_PROXY' in strut.conf (valid: nginx, caddy)" ;;
  esac
}

# resolve_strut_home <script_path>
#
# Resolves the real path of the given script (following symlinks) to
# determine Strut_Home. Sets STRUT_HOME to the directory containing
# the real script.
#
# Args:
#   script_path — path to the strut entrypoint (typically $0 or ${BASH_SOURCE[0]})
#
# Side effects: Sets and exports STRUT_HOME
resolve_strut_home() {
  local script="${1:-${BASH_SOURCE[0]}}"

  # Follow symlinks to find the real script location
  while [ -L "$script" ]; do
    local link_target
    link_target="$(readlink "$script")"
    # Handle relative symlinks
    if [[ "$link_target" != /* ]]; then
      link_target="$(dirname "$script")/$link_target"
    fi
    script="$link_target"
  done

  # Resolve to absolute path and get directory
  STRUT_HOME="$(cd "$(dirname "$script")" && pwd)"
  export STRUT_HOME
}
