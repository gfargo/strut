#!/usr/bin/env bats
# ==================================================
# tests/test_config_include.bats — `include = <path>` directive
# ==================================================

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  # Stub fail so tests can catch aborts
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"
  fail() { echo "FAIL: $1" >&2; return 1; }
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── Smoke ─────────────────────────────────────────────────────────────────────

@test "preprocess_config: passthrough when no include directive" {
  cat > "$TEST_TMP/a.conf" <<EOF
KEY=value
OTHER=foo
EOF
  run preprocess_config "$TEST_TMP/a.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY=value"* ]]
  [[ "$output" == *"OTHER=foo"* ]]
}

@test "preprocess_config: expands include inline before child content" {
  cat > "$TEST_TMP/base.conf" <<EOF
FROM_BASE=1
EOF
  cat > "$TEST_TMP/child.conf" <<EOF
include = base.conf
FROM_CHILD=1
EOF
  run preprocess_config "$TEST_TMP/child.conf"
  [ "$status" -eq 0 ]
  # Base must appear before child so later assignments override
  local base_line child_line
  base_line=$(echo "$output" | grep -n "FROM_BASE" | cut -d: -f1)
  child_line=$(echo "$output" | grep -n "FROM_CHILD" | cut -d: -f1)
  [ "$base_line" -lt "$child_line" ]
}

@test "preprocess_config: child assignment overrides base when both sourced" {
  cat > "$TEST_TMP/base.conf" <<EOF
BANNER=base
EOF
  cat > "$TEST_TMP/child.conf" <<EOF
include = base.conf
BANNER=child
EOF
  # shellcheck disable=SC1090
  source <(preprocess_config "$TEST_TMP/child.conf")
  [ "$BANNER" = "child" ]
}

@test "preprocess_config: relative include resolves against including file's dir" {
  mkdir -p "$TEST_TMP/a/b"
  cat > "$TEST_TMP/a/base.conf" <<EOF
VAR=ok
EOF
  cat > "$TEST_TMP/a/b/child.conf" <<EOF
include = ../base.conf
EOF
  # shellcheck disable=SC1090
  source <(preprocess_config "$TEST_TMP/a/b/child.conf")
  [ "$VAR" = "ok" ]
}

@test "preprocess_config: absolute include path works" {
  cat > "$TEST_TMP/base.conf" <<EOF
VAR=abs
EOF
  cat > "$TEST_TMP/child.conf" <<EOF
include = $TEST_TMP/base.conf
EOF
  # shellcheck disable=SC1090
  source <(preprocess_config "$TEST_TMP/child.conf")
  [ "$VAR" = "abs" ]
}

@test "preprocess_config: multiple includes processed in order" {
  cat > "$TEST_TMP/a.conf" <<EOF
FROM_A=1
EOF
  cat > "$TEST_TMP/b.conf" <<EOF
FROM_B=1
EOF
  cat > "$TEST_TMP/child.conf" <<EOF
include = a.conf
include = b.conf
EOF
  # shellcheck disable=SC1090
  source <(preprocess_config "$TEST_TMP/child.conf")
  [ "$FROM_A" = "1" ]
  [ "$FROM_B" = "1" ]
}

@test "preprocess_config: later include overrides earlier include" {
  cat > "$TEST_TMP/a.conf" <<EOF
X=1
EOF
  cat > "$TEST_TMP/b.conf" <<EOF
X=2
EOF
  cat > "$TEST_TMP/child.conf" <<EOF
include = a.conf
include = b.conf
EOF
  # shellcheck disable=SC1090
  source <(preprocess_config "$TEST_TMP/child.conf")
  [ "$X" = "2" ]
}

@test "preprocess_config: circular include rejected" {
  cat > "$TEST_TMP/a.conf" <<EOF
include = b.conf
EOF
  cat > "$TEST_TMP/b.conf" <<EOF
include = a.conf
EOF
  run preprocess_config "$TEST_TMP/a.conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"circular"* ]] || [[ "$output" == *"FAIL"* ]]
}

@test "preprocess_config: missing include target fails with clear message" {
  cat > "$TEST_TMP/child.conf" <<EOF
include = nonexistent.conf
EOF
  run preprocess_config "$TEST_TMP/child.conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "preprocess_config: comment line starting with # is passthrough even if contains include" {
  cat > "$TEST_TMP/child.conf" <<EOF
# include = nonexistent.conf
KEY=value
EOF
  run preprocess_config "$TEST_TMP/child.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"include = nonexistent.conf"* ]]
}

@test "preprocess_config: quoted include path accepted" {
  cat > "$TEST_TMP/base.conf" <<EOF
VAR=quoted
EOF
  cat > "$TEST_TMP/child.conf" <<EOF
include = "base.conf"
EOF
  # shellcheck disable=SC1090
  source <(preprocess_config "$TEST_TMP/child.conf")
  [ "$VAR" = "quoted" ]
}

@test "preprocess_config: plain-text file (required_vars style) supports include" {
  cat > "$TEST_TMP/common.vars" <<EOF
DB_URL
SECRET_KEY
EOF
  cat > "$TEST_TMP/stack.vars" <<EOF
include = common.vars
STACK_SPECIFIC_VAR
EOF
  run preprocess_config "$TEST_TMP/stack.vars"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_URL"* ]]
  [[ "$output" == *"SECRET_KEY"* ]]
  [[ "$output" == *"STACK_SPECIFIC_VAR"* ]]
}

@test "preprocess_config: nested includes (A -> B -> C) work" {
  cat > "$TEST_TMP/c.conf" <<EOF
FROM_C=1
EOF
  cat > "$TEST_TMP/b.conf" <<EOF
include = c.conf
FROM_B=1
EOF
  cat > "$TEST_TMP/a.conf" <<EOF
include = b.conf
FROM_A=1
EOF
  # shellcheck disable=SC1090
  source <(preprocess_config "$TEST_TMP/a.conf")
  [ "$FROM_A" = "1" ]
  [ "$FROM_B" = "1" ]
  [ "$FROM_C" = "1" ]
}

@test "preprocess_config: include without whitespace around = works" {
  cat > "$TEST_TMP/base.conf" <<EOF
VAR=nospaces
EOF
  cat > "$TEST_TMP/child.conf" <<EOF
include=base.conf
EOF
  # shellcheck disable=SC1090
  source <(preprocess_config "$TEST_TMP/child.conf")
  [ "$VAR" = "nospaces" ]
}

# ── Integration with actual loaders ──────────────────────────────────────────

@test "load_strut_config: applies include from strut.conf" {
  mkdir -p "$TEST_TMP/.strut"
  cat > "$TEST_TMP/.strut/base.conf" <<EOF
REGISTRY_TYPE=ghcr
DEFAULT_ORG=shared-org
BANNER_TEXT=shared
EOF
  cat > "$TEST_TMP/strut.conf" <<EOF
include = .strut/base.conf
BANNER_TEXT=child-banner
EOF
  export PROJECT_ROOT="$TEST_TMP"
  load_strut_config
  [ "$REGISTRY_TYPE" = "ghcr" ]
  [ "$DEFAULT_ORG" = "shared-org" ]
  [ "$BANNER_TEXT" = "child-banner" ]
}

@test "load_services_conf: applies include from services.conf" {
  mkdir -p "$TEST_TMP/stacks/api"
  cat > "$TEST_TMP/common.conf" <<EOF
COMMON_PORT=9000
EOF
  cat > "$TEST_TMP/stacks/api/services.conf" <<EOF
include = ../../common.conf
API_PORT=8080
EOF
  load_services_conf "$TEST_TMP/stacks/api"
  [ "$COMMON_PORT" = "9000" ]
  [ "$API_PORT" = "8080" ]
}
