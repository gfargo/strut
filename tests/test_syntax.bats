#!/usr/bin/env bats
# ==================================================
# tests/test_syntax.bats — Bash syntax validation for all .sh files
# ==================================================
# Run:  bats tests/test_syntax.bats
# Catches syntax errors that would cause runtime failures.

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "strut entrypoint passes bash -n syntax check" {
  bash -n "$CLI_ROOT/strut"
}

@test "all lib/*.sh files pass bash -n syntax check" {
  local failures=()
  for f in "$CLI_ROOT"/lib/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      failures+=("$(basename "$f")")
    fi
  done
  if [ ${#failures[@]} -gt 0 ]; then
    echo "Syntax errors in: ${failures[*]}" >&2
    return 1
  fi
}

@test "all lib/backup/*.sh files pass bash -n syntax check" {
  local failures=()
  for f in "$CLI_ROOT"/lib/backup/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      failures+=("$(basename "$f")")
    fi
  done
  if [ ${#failures[@]} -gt 0 ]; then
    echo "Syntax errors in lib/backup/: ${failures[*]}" >&2
    return 1
  fi
}

@test "all lib/drift/*.sh files pass bash -n syntax check" {
  local failures=()
  for f in "$CLI_ROOT"/lib/drift/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      failures+=("$(basename "$f")")
    fi
  done
  if [ ${#failures[@]} -gt 0 ]; then
    echo "Syntax errors in lib/drift/: ${failures[*]}" >&2
    return 1
  fi
}

@test "all lib/keys/*.sh files pass bash -n syntax check" {
  local failures=()
  for f in "$CLI_ROOT"/lib/keys/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      failures+=("$(basename "$f")")
    fi
  done
  if [ ${#failures[@]} -gt 0 ]; then
    echo "Syntax errors in lib/keys/: ${failures[*]}" >&2
    return 1
  fi
}

@test "all lib/migrate/*.sh files pass bash -n syntax check" {
  local failures=()
  for f in "$CLI_ROOT"/lib/migrate/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      failures+=("$(basename "$f")")
    fi
  done
  if [ ${#failures[@]} -gt 0 ]; then
    echo "Syntax errors in lib/migrate/: ${failures[*]}" >&2
    return 1
  fi
}

@test "all scripts/*.sh files pass bash -n syntax check (if present)" {
  local failures=()
  for f in "$CLI_ROOT"/scripts/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      failures+=("$(basename "$f")")
    fi
  done
  if [ ${#failures[@]} -gt 0 ]; then
    echo "Syntax errors in scripts/: ${failures[*]}" >&2
    return 1
  fi
}
