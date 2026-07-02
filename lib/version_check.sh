#!/usr/bin/env bash
# ==================================================
# lib/version_check.sh — Lightweight update-available nag
# ==================================================
# Provides:
#   strut_latest_version    — fetch latest release tag from GitHub API
#   strut_check_for_update  — print one-line hint when a newer version exists
#
# The check is:
#   - cached for 24 hours in ~/.cache/strut/latest_version
#   - completely suppressed when:
#       STRUT_NO_UPDATE_CHECK=1
#       CI=1  (any CI environment)
#       stderr is not a TTY (scripted / piped usage)
#       --json output mode is active (OUTPUT_MODE=json)
#   - never blocking (network call has a short timeout; failures are silent)
#   - output goes to stderr only

set -euo pipefail

# strut_latest_version
# Fetch the latest published release tag from GitHub and print the bare
# version number (without leading "v").  Returns non-zero on failure.
strut_latest_version() {
  local tag
  tag=$(curl -fsSL --max-time 3 \
    "https://api.github.com/repos/gfargo/strut/releases/latest" \
    2>/dev/null \
    | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | grep -Eo '"[^"]*"$' \
    | tr -d '"') || return 1
  # Strip leading "v" if present
  echo "${tag#v}"
}

# _strut_version_gt <a> <b>
# Returns 0 (true) when version string a is strictly greater than b.
# Compares dotted-numeric versions only (e.g. 0.28.0 vs 0.25.1).
_strut_version_gt() {
  local a="$1"
  local b="$2"
  # Use sort -V when available (GNU coreutils), otherwise fall back to
  # a simple integer-field comparison.
  if command -v sort > /dev/null 2>&1 && sort --version 2>&1 | grep -q GNU; then
    local highest
    highest=$(printf '%s\n%s\n' "$a" "$b" | sort -rV | head -1)
    [ "$highest" = "$a" ] && [ "$a" != "$b" ]
    return
  fi
  # Fallback: split on "." and compare field by field
  local IFS=.
  # shellcheck disable=SC2206
  local a_parts=($a) b_parts=($b)
  local i
  for i in 0 1 2; do
    local av="${a_parts[$i]:-0}"
    local bv="${b_parts[$i]:-0}"
    if [ "$av" -gt "$bv" ]; then return 0; fi
    if [ "$av" -lt "$bv" ]; then return 1; fi
  done
  return 1  # equal
}

# strut_check_for_update
# Print a one-line update hint to stderr when a newer version is available.
# Returns 0 in all cases (never fails the caller).
strut_check_for_update() {
  # --- Early-exit conditions ---

  # Explicit opt-out
  if [ "${STRUT_NO_UPDATE_CHECK:-}" = "1" ]; then
    return 0
  fi

  # CI environments
  if [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]; then
    return 0
  fi

  # Non-TTY stderr (scripted/piped output)
  if [ ! -t 2 ]; then
    return 0
  fi

  # JSON output mode (don't pollute machine-readable output)
  if [ "${OUTPUT_MODE:-}" = "json" ]; then
    return 0
  fi

  # --- Cache handling ---
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/strut"
  local cache_file="$cache_dir/latest_version"
  local ttl=86400  # 24 hours in seconds

  # Determine whether the cache is still fresh
  local cache_fresh=false
  if [ -f "$cache_file" ]; then
    local now
    now=$(date +%s 2>/dev/null) || now=0
    local mtime
    # Portable mtime: Linux uses stat -c, macOS uses stat -f
    if stat --version 2>&1 | grep -q GNU; then
      mtime=$(stat -c '%Y' "$cache_file" 2>/dev/null) || mtime=0
    else
      mtime=$(stat -f '%m' "$cache_file" 2>/dev/null) || mtime=0
    fi
    local age=$(( now - mtime ))
    if [ "$age" -lt "$ttl" ]; then
      cache_fresh=true
    fi
  fi

  local latest=""
  if $cache_fresh; then
    latest=$(cat "$cache_file" 2>/dev/null) || latest=""
  else
    # Fetch with a short timeout; silently skip if network is unavailable
    latest=$(strut_latest_version 2>/dev/null) || latest=""
    if [ -n "$latest" ]; then
      mkdir -p "$cache_dir" 2>/dev/null || true
      printf '%s' "$latest" > "$cache_file" 2>/dev/null || true
    fi
  fi

  [ -n "$latest" ] || return 0

  # --- Compare versions ---
  local current=""
  local version_file="${STRUT_HOME:-}/VERSION"
  if [ -f "$version_file" ]; then
    current=$(cat "$version_file" | tr -d '[:space:]') || current=""
  fi

  [ -n "$current" ] || return 0

  if _strut_version_gt "$latest" "$current"; then
    echo "  ℹ  strut $latest is available (you have $current). Run: strut upgrade" >&2
  fi

  return 0
}
