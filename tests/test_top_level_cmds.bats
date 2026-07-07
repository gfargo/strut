#!/usr/bin/env bats
# ==================================================
# tests/test_top_level_cmds.bats — Tests for top-level commands
# ==================================================
# Covers: --version, init, upgrade dispatch routing
# Run:  bats tests/test_top_level_cmds.bats

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── --version ─────────────────────────────────────────────────────────────────

@test "strut --version outputs version from VERSION file" {
  run bash "$CLI" --version
  [ "$status" -eq 0 ]
  # Should match the content of VERSION file
  local expected
  expected=$(cat "$CLI_ROOT/VERSION" | tr -d '[:space:]')
  local actual
  actual=$(echo "$output" | tr -d '[:space:]')
  [ "$actual" = "$expected" ]
}

@test "strut -v outputs version" {
  run bash "$CLI" -v
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "strut version outputs version" {
  run bash "$CLI" version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

# ── init ──────────────────────────────────────────────────────────────────────

@test "strut init creates strut.conf and stacks/" {
  run bash -c "cd '$TEST_TMP' && STRUT_HOME='$CLI_ROOT' bash '$CLI' init"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/strut.conf" ]
  [ -d "$TEST_TMP/stacks" ]
  [ -f "$TEST_TMP/.gitignore" ]
}

@test "strut init --registry ghcr sets REGISTRY_TYPE" {
  run bash -c "cd '$TEST_TMP' && STRUT_HOME='$CLI_ROOT' bash '$CLI' init --registry ghcr"
  [ "$status" -eq 0 ]
  grep -q "^REGISTRY_TYPE=ghcr" "$TEST_TMP/strut.conf"
}

@test "strut init --org my-org sets DEFAULT_ORG" {
  run bash -c "cd '$TEST_TMP' && STRUT_HOME='$CLI_ROOT' bash '$CLI' init --org my-org"
  [ "$status" -eq 0 ]
  grep -q 'DEFAULT_ORG=.*my-org' "$TEST_TMP/strut.conf"
}

@test "strut init fails if already initialized" {
  echo "# existing" > "$TEST_TMP/strut.conf"
  run bash -c "cd '$TEST_TMP' && STRUT_HOME='$CLI_ROOT' bash '$CLI' init"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already initialized"* ]]
}

# ── upgrade ───────────────────────────────────────────────────────────────────

@test "strut upgrade prints instructions when STRUT_HOME is not a git repo or brew install" {
  # With an unknown install method, cmd_upgrade should print re-install
  # instructions and exit 0 (not fatal).
  local fake_home="$TEST_TMP/not-git"
  mkdir -p "$fake_home"
  run bash -c "
    source '$CLI_ROOT/lib/utils.sh'
    fail() { echo \"\$1\" >&2; return 1; }
    warn() { echo \"WARN: \$*\" >&2; }
    log()  { echo \"LOG: \$*\"; }
    ok()   { echo \"OK: \$*\"; }
    DEFAULT_BRANCH=main
    export -f fail warn log ok
    STRUT_HOME='$fake_home'
    export STRUT_HOME
    source '$CLI_ROOT/lib/cmd_upgrade.sh'
    cmd_upgrade
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-install"* ]] || [[ "$output" == *"install.sh"* ]]
}
