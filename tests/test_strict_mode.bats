#!/usr/bin/env bats
# ==================================================
# tests/test_strict_mode.bats — Verify all lib files have strict mode
# ==================================================
# Run:  bats tests/test_strict_mode.bats
# Covers: CLI-312 — set -euo pipefail in all lib files

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB_DIR="$CLI_ROOT/lib"
}

@test "strut entrypoint has set -euo pipefail" {
  grep -q 'set -euo pipefail' "$CLI_ROOT/strut"
}

@test "all top-level lib/*.sh files have set -euo pipefail" {
  local missing=()
  for f in "$LIB_DIR"/*.sh; do
    [ -f "$f" ] || continue
    if ! grep -q 'set -euo pipefail' "$f"; then
      missing+=("$(basename "$f")")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing strict mode in: ${missing[*]}" >&2
    return 1
  fi
}

@test "all lib/backup/*.sh files have set -euo pipefail" {
  local missing=()
  for f in "$LIB_DIR"/backup/*.sh; do
    [ -f "$f" ] || continue
    if ! grep -q 'set -euo pipefail' "$f"; then
      missing+=("$(basename "$f")")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing strict mode in lib/backup/: ${missing[*]}" >&2
    return 1
  fi
}

@test "all lib/drift/*.sh files have set -euo pipefail" {
  local missing=()
  for f in "$LIB_DIR"/drift/*.sh; do
    [ -f "$f" ] || continue
    if ! grep -q 'set -euo pipefail' "$f"; then
      missing+=("$(basename "$f")")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing strict mode in lib/drift/: ${missing[*]}" >&2
    return 1
  fi
}

@test "all lib/keys/*.sh files have set -euo pipefail" {
  local missing=()
  for f in "$LIB_DIR"/keys/*.sh; do
    [ -f "$f" ] || continue
    if ! grep -q 'set -euo pipefail' "$f"; then
      missing+=("$(basename "$f")")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing strict mode in lib/keys/: ${missing[*]}" >&2
    return 1
  fi
}

@test "all lib/migrate/*.sh files have set -euo pipefail" {
  local missing=()
  for f in "$LIB_DIR"/migrate/*.sh; do
    [ -f "$f" ] || continue
    if ! grep -q 'set -euo pipefail' "$f"; then
      missing+=("$(basename "$f")")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing strict mode in lib/migrate/: ${missing[*]}" >&2
    return 1
  fi
}

@test "all lib/cmd_*.sh files have set -euo pipefail" {
  local missing=()
  for f in "$LIB_DIR"/cmd_*.sh; do
    [ -f "$f" ] || continue
    if ! grep -q 'set -euo pipefail' "$f"; then
      missing+=("$(basename "$f")")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing strict mode in cmd handlers: ${missing[*]}" >&2
    return 1
  fi
}
