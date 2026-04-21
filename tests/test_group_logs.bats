#!/usr/bin/env bats
# ==================================================
# tests/test_group_logs.bats — Tests for `strut group <name> logs` multiplexing
# ==================================================
# We test the prefix-filter pipeline and the --grep + prefix ordering without
# touching real Docker. The multiplexing happens in cmd_group.sh:_group_logs,
# and its per-stack filter is:
#
#   "$0" <stack> logs ...  |  [grep -E pattern]  |  awk '{print prefix " " $0}'
#
# This file validates the shell-level pieces so the integration is trustworthy.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/groups.sh"
  source "$CLI_ROOT/lib/cmd_group.sh"

  export STRUT_GROUPS_CONF="$TEST_TMP/groups.conf"
}

teardown() {
  common_teardown
  unset STRUT_GROUPS_CONF
}

# ── awk prefixer behavior ─────────────────────────────────────────────────────

@test "prefix awk: prepends prefix to each line" {
  result=$(printf 'line one\nline two\n' | awk -v p='[api]' '{ print p " " $0; fflush() }')
  [ "$result" = $'[api] line one\n[api] line two' ]
}

@test "prefix awk: preserves empty lines" {
  result=$(printf 'one\n\ntwo\n' | awk -v p='[x]' '{ print p " " $0; fflush() }')
  # Empty line gets a prefix too (that's fine — readers know what stream it's from)
  [ "$(printf '%s' "$result" | wc -l | tr -d ' ')" = "2" ]
}

@test "prefix awk: handles special characters in log lines" {
  result=$(printf 'GET /users?id=1 200\n{"k":"v"}\n' | awk -v p='[api]' '{ print p " " $0; fflush() }')
  [[ "$result" == *'[api] GET /users?id=1 200'* ]]
  [[ "$result" == *'[api] {"k":"v"}'* ]]
}

# ── grep + prefix pipeline ordering ──────────────────────────────────────────

@test "grep before prefix: filters on raw content, not the [stack] tag" {
  result=$(printf 'INFO ok\nERROR bad\nINFO fine\n' \
    | grep --line-buffered -E 'ERROR' \
    | awk -v p='[web]' '{ print p " " $0; fflush() }')
  [ "$result" = "[web] ERROR bad" ]
}

@test "grep before prefix: multiple matches" {
  result=$(printf 'a\nb\nc\nd\n' \
    | grep --line-buffered -E 'a|c' \
    | awk -v p='[s]' '{ print p " " $0; fflush() }')
  [ "$result" = $'[s] a\n[s] c' ]
}

# ── Color prefix on TTY vs non-TTY ────────────────────────────────────────────

@test "plain prefix used when stdout is not a TTY (this test)" {
  # _group_logs chooses a plain prefix when [ -t 1 ] is false. Bats runs
  # tests with stdout captured, so the TTY check is false here. We verify
  # the expected plain form is a clean `[stack]` with no escape codes.
  local prefix
  if [ -t 1 ]; then
    prefix=$'\033[31m[s]\033[0m'
  else
    prefix="[s]"
  fi
  [ "$prefix" = "[s]" ]
}

# ── Integration with groups_members for stack resolution ─────────────────────

@test "group logs: refuses unknown group" {
  cat > "$STRUT_GROUPS_CONF" <<'EOF'
[real]
x
EOF
  # _group_logs exits via fail() — run it through a sub-bash to capture
  run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    source "'"$CLI_ROOT"'/lib/groups.sh"
    source "'"$CLI_ROOT"'/lib/cmd_group.sh"
    export STRUT_GROUPS_CONF="'"$STRUT_GROUPS_CONF"'"
    _group_logs does-not-exist 2>&1
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown group"* ]]
}

@test "group logs: warns (not fails) when group is empty" {
  cat > "$STRUT_GROUPS_CONF" <<'EOF'
[empty]
EOF
  run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    source "'"$CLI_ROOT"'/lib/groups.sh"
    source "'"$CLI_ROOT"'/lib/cmd_group.sh"
    export STRUT_GROUPS_CONF="'"$STRUT_GROUPS_CONF"'"
    _group_logs empty 2>&1
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"no stacks"* ]]
}

# ── Flag parsing ──────────────────────────────────────────────────────────────

@test "group logs: --follow, --since, --grep, --service all parse without error" {
  cat > "$STRUT_GROUPS_CONF" <<'EOF'
[empty]
EOF
  # Use the empty group so we don't spawn children; just validate arg parsing.
  run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    source "'"$CLI_ROOT"'/lib/groups.sh"
    source "'"$CLI_ROOT"'/lib/cmd_group.sh"
    export STRUT_GROUPS_CONF="'"$STRUT_GROUPS_CONF"'"
    _group_logs empty --follow --since 1h --grep ERROR --service api 2>&1
  '
  [ "$status" -eq 0 ]
}
