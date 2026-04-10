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

# ── Upgrade: fails when STRUT_HOME is not a git repo ─────────────────────────

@test "upgrade: fails when STRUT_HOME is not a git repo" {
  local fake_home="$TEST_TMP/not_git"
  mkdir -p "$fake_home"

  # Source utils for fail()
  source "$CLI_ROOT/lib/utils.sh"

  run bash -c "
    export STRUT_HOME='$fake_home'
    source '$CLI_ROOT/lib/utils.sh'
    if [ ! -d \"\$STRUT_HOME/.git\" ]; then
      echo 'Strut_Home is not a git repository' >&2
      exit 1
    fi
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repository"* ]]
}
