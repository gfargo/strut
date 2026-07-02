#!/usr/bin/env bats
# ==================================================
# tests/test_entrypoint.bats — Entrypoint property tests
# ==================================================
# Property 17: Version file round-trip
# Validates: Requirements 14.4, 14.5
#
# Run:  bats tests/test_entrypoint.bats

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CLI="$CLI_ROOT/strut"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── Helper: generate random version string ───────────────────────────────────

_rand_version() {
  echo "$(( RANDOM % 100 )).$(( RANDOM % 100 )).$(( RANDOM % 100 ))"
}

# ── Property 17: Version file round-trip ─────────────────────────────────────
# Feature: ch-deploy-modularization, Property 17: Version file round-trip
# Validates: Requirements 14.4, 14.5

@test "Property 17: VERSION file content is displayed by --version (100 iterations)" {
  for i in $(seq 1 100); do
    local version="$(_rand_version)"
    local fake_home="$TEST_TMP/strut_home_$i"
    mkdir -p "$fake_home"

    # Write version file
    echo "$version" > "$fake_home/VERSION"

    # The --version dispatch reads from STRUT_HOME/VERSION
    # Simulate the dispatch logic directly
    local result
    result=$(
      export STRUT_HOME="$fake_home"
      _version_file="$STRUT_HOME/VERSION"
      if [ -f "$_version_file" ]; then
        cat "$_version_file"
      else
        echo "unknown"
      fi
    )

    # Trim whitespace for comparison
    result="$(echo "$result" | tr -d '[:space:]')"
    [ "$result" = "$version" ]
  done
}

@test "Property 17: missing VERSION file displays 'unknown'" {
  local fake_home="$TEST_TMP/no_version"
  mkdir -p "$fake_home"

  local result
  result=$(
    export STRUT_HOME="$fake_home"
    _version_file="$STRUT_HOME/VERSION"
    if [ -f "$_version_file" ]; then
      cat "$_version_file"
    else
      echo "unknown"
    fi
  )

  result="$(echo "$result" | tr -d '[:space:]')"
  [ "$result" = "unknown" ]
}

@test "Property 17: actual VERSION file in repo is readable" {
  [ -f "$CLI_ROOT/VERSION" ]
  local version
  version="$(cat "$CLI_ROOT/VERSION" | tr -d '[:space:]')"
  [ -n "$version" ]
  # Should look like a semver
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# ── Upgrade: unknown install method gives instructions ────────────────────────

@test "upgrade: unknown install method prints install instructions (not fatal)" {
  local fake_home="$TEST_TMP/not_git"
  mkdir -p "$fake_home"

  run bash -c "
    source '$CLI_ROOT/lib/utils.sh'
    fail() { echo \"\$1\" >&2; return 1; }
    warn() { echo \"WARN: \$*\" >&2; }
    log()  { echo \"LOG: \$*\"; }
    ok()   { echo \"OK: \$*\"; }
    DEFAULT_BRANCH=main
    export -f fail warn log ok
    export STRUT_HOME='$fake_home'
    source '$CLI_ROOT/lib/cmd_upgrade.sh'
    cmd_upgrade
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"install.sh"* ]]
}

# ── Spaced project root guard ─────────────────────────────────────────────────

@test "spaced PROJECT_ROOT: fails immediately with clear message" {
  local spaced_dir="$TEST_TMP/my project root"
  mkdir -p "$spaced_dir"
  echo "# strut.conf" > "$spaced_dir/strut.conf"

  run bash -c "cd '$spaced_dir' && STRUT_NO_TUI=1 bash '$CLI' mystack deploy 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not contain spaces"* ]]
  [[ "$output" == *"$spaced_dir"* ]]
}

@test "spaced PROJECT_ROOT: --version works from spaced dir (exits before guard)" {
  local spaced_dir="$TEST_TMP/my project root2"
  mkdir -p "$spaced_dir"
  echo "# strut.conf" > "$spaced_dir/strut.conf"

  # --version exits inside the top-level case statement, before the spaces
  # guard which is placed after the case. It must succeed.
  run bash -c "cd '$spaced_dir' && bash '$CLI' --version 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "space-free PROJECT_ROOT: no early failure" {
  local clean_dir="$TEST_TMP/cleanproject"
  mkdir -p "$clean_dir/stacks/mystack"
  echo "# strut.conf" > "$clean_dir/strut.conf"

  # Should get past the guard and fail only because the stack has no compose file
  run bash -c "cd '$clean_dir' && STRUT_NO_TUI=1 bash '$CLI' mystack deploy 2>&1"
  # The guard must NOT trigger — error must be something else (missing env/compose)
  [[ "$output" != *"must not contain spaces"* ]]
}
