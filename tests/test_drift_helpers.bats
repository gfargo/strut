#!/usr/bin/env bats
# ==================================================
# tests/test_drift_helpers.bats — Tests for lib/drift.sh pure functions
# ==================================================
# Run:  bats tests/test_drift_helpers.bats
# Covers: drift_load_ignore_patterns, drift_should_ignore, DRIFT_TRACKED_FILES

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  # Source utils with fail() overridden
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }

  # Source drift.sh (it re-sources utils if RED is empty, so set it)
  export RED GREEN YELLOW BLUE NC
  source "$CLI_ROOT/lib/drift.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── DRIFT_TRACKED_FILES ──────────────────────────────────────────────────────

@test "DRIFT_TRACKED_FILES: array is non-empty" {
  [ "${#DRIFT_TRACKED_FILES[@]}" -gt 0 ]
}

@test "DRIFT_TRACKED_FILES: contains docker-compose.yml" {
  local found=false
  for f in "${DRIFT_TRACKED_FILES[@]}"; do
    [[ "$f" == "docker-compose.yml" ]] && found=true
  done
  [ "$found" = "true" ]
}

@test "DRIFT_TRACKED_FILES: contains .env.template" {
  local found=false
  for f in "${DRIFT_TRACKED_FILES[@]}"; do
    [[ "$f" == ".env.template" ]] && found=true
  done
  [ "$found" = "true" ]
}

@test "DRIFT_TRACKED_FILES: contains backup.conf" {
  local found=false
  for f in "${DRIFT_TRACKED_FILES[@]}"; do
    [[ "$f" == "backup.conf" ]] && found=true
  done
  [ "$found" = "true" ]
}

# ── drift_load_ignore_patterns ────────────────────────────────────────────────

@test "drift_load_ignore_patterns: loads patterns from .drift-ignore" {
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/.drift-ignore" <<'EOF'
*.bak
*.log
temp/*
EOF
  drift_load_ignore_patterns "$TEST_TMP/stack"
  [ "${#DRIFT_IGNORE_PATTERNS[@]}" -eq 3 ]
  [ "${DRIFT_IGNORE_PATTERNS[0]}" = "*.bak" ]
  [ "${DRIFT_IGNORE_PATTERNS[1]}" = "*.log" ]
  [ "${DRIFT_IGNORE_PATTERNS[2]}" = "temp/*" ]
}

@test "drift_load_ignore_patterns: skips comments and empty lines" {
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/.drift-ignore" <<'EOF'
# This is a comment
*.bak

# Another comment

*.log
EOF
  drift_load_ignore_patterns "$TEST_TMP/stack"
  [ "${#DRIFT_IGNORE_PATTERNS[@]}" -eq 2 ]
  [ "${DRIFT_IGNORE_PATTERNS[0]}" = "*.bak" ]
  [ "${DRIFT_IGNORE_PATTERNS[1]}" = "*.log" ]
}

@test "drift_load_ignore_patterns: returns empty array when no .drift-ignore" {
  mkdir -p "$TEST_TMP/stack"
  drift_load_ignore_patterns "$TEST_TMP/stack"
  [ "${#DRIFT_IGNORE_PATTERNS[@]}" -eq 0 ]
}

@test "drift_load_ignore_patterns: handles file with only comments" {
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/.drift-ignore" <<'EOF'
# comment 1
# comment 2
EOF
  drift_load_ignore_patterns "$TEST_TMP/stack"
  [ "${#DRIFT_IGNORE_PATTERNS[@]}" -eq 0 ]
}

# ── drift_should_ignore ──────────────────────────────────────────────────────

@test "drift_should_ignore: matches exact filename pattern" {
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/.drift-ignore" <<'EOF'
backup.conf
EOF
  run drift_should_ignore "$TEST_TMP/stack/backup.conf" "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
}

@test "drift_should_ignore: matches wildcard pattern" {
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/.drift-ignore" <<'EOF'
*.bak
EOF
  run drift_should_ignore "$TEST_TMP/stack/docker-compose.yml.bak" "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
}

@test "drift_should_ignore: returns 1 for non-matching file" {
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/.drift-ignore" <<'EOF'
*.bak
*.log
EOF
  run drift_should_ignore "$TEST_TMP/stack/docker-compose.yml" "$TEST_TMP/stack"
  [ "$status" -eq 1 ]
}

@test "drift_should_ignore: returns 1 when no .drift-ignore exists" {
  mkdir -p "$TEST_TMP/stack"
  run drift_should_ignore "$TEST_TMP/stack/docker-compose.yml" "$TEST_TMP/stack"
  [ "$status" -eq 1 ]
}

@test "drift_should_ignore: matches directory wildcard pattern" {
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/.drift-ignore" <<'EOF'
nginx/*
EOF
  run drift_should_ignore "$TEST_TMP/stack/nginx/nginx.conf" "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
}
