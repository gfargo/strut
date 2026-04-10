#!/usr/bin/env bats
# ==================================================
# tests/test_drift_helpers.bats — Tests for lib/drift.sh pure functions
# ==================================================
# Run:  bats tests/test_drift_helpers.bats
# Covers: drift_load_ignore_patterns, drift_should_ignore, drift_get_tracked_files

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

# ── drift_get_tracked_files ──────────────────────────────────────────────────

@test "drift_get_tracked_files: returns non-empty list" {
  local -a tracked_files
  IFS=' ' read -ra tracked_files <<< "$(drift_get_tracked_files)"
  [ "${#tracked_files[@]}" -gt 0 ]
}

@test "drift_get_tracked_files: contains docker-compose.yml" {
  local -a tracked_files
  IFS=' ' read -ra tracked_files <<< "$(drift_get_tracked_files)"
  local found=false
  for f in "${tracked_files[@]}"; do
    [[ "$f" == "docker-compose.yml" ]] && found=true
  done
  [ "$found" = "true" ]
}

@test "drift_get_tracked_files: contains .env.template" {
  local -a tracked_files
  IFS=' ' read -ra tracked_files <<< "$(drift_get_tracked_files)"
  local found=false
  for f in "${tracked_files[@]}"; do
    [[ "$f" == ".env.template" ]] && found=true
  done
  [ "$found" = "true" ]
}

@test "drift_get_tracked_files: contains backup.conf" {
  local -a tracked_files
  IFS=' ' read -ra tracked_files <<< "$(drift_get_tracked_files)"
  local found=false
  for f in "${tracked_files[@]}"; do
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
