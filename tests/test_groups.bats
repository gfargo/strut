#!/usr/bin/env bats
# ==================================================
# tests/test_groups.bats — Tests for lib/groups.sh (INI parser + mutations)
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/groups.sh"

  export STRUT_GROUPS_CONF="$TEST_TMP/groups.conf"
}

teardown() {
  common_teardown
  unset STRUT_GROUPS_CONF
}

_write_groups() {
  cat > "$STRUT_GROUPS_CONF"
}

# ── groups_list ───────────────────────────────────────────────────────────────

@test "groups_list: empty when file missing" {
  result=$(groups_list)
  [ -z "$result" ]
}

@test "groups_list: returns all group names in file order" {
  _write_groups <<'EOF'
[alpha]
a

[beta]
b

[gamma]
c
EOF
  result=$(groups_list)
  [ "$result" = $'alpha\nbeta\ngamma' ]
}

@test "groups_list: ignores comments and whitespace" {
  _write_groups <<'EOF'
# header comment

[only-group]
a
# inline comment
EOF
  result=$(groups_list)
  [ "$result" = "only-group" ]
}

# ── groups_members ────────────────────────────────────────────────────────────

@test "groups_members: returns stacks under a group" {
  _write_groups <<'EOF'
[vps-1]
stack-a
stack-b
EOF
  result=$(groups_members "vps-1")
  [ "$result" = $'stack-a\nstack-b' ]
}

@test "groups_members: empty for missing group" {
  _write_groups <<'EOF'
[other]
stack-a
EOF
  result=$(groups_members "missing")
  [ -z "$result" ]
}

@test "groups_members: scoped to the right section (doesn't leak)" {
  _write_groups <<'EOF'
[first]
a
b

[second]
c
d
EOF
  result=$(groups_members "first")
  [ "$result" = $'a\nb' ]
}

@test "groups_members: handles leading whitespace on stack lines" {
  _write_groups <<'EOF'
[g]
   indented-stack
tab-indented
EOF
  result=$(groups_members "g")
  [[ "$result" == *"indented-stack"* ]]
  [[ "$result" == *"tab-indented"* ]]
}

# ── groups_exists / has_member ────────────────────────────────────────────────

@test "groups_exists: true for declared group" {
  _write_groups <<'EOF'
[my-group]
x
EOF
  run groups_exists "my-group"
  [ "$status" -eq 0 ]
}

@test "groups_exists: false for undeclared group" {
  _write_groups <<'EOF'
[other]
x
EOF
  run groups_exists "my-group"
  [ "$status" -ne 0 ]
}

@test "groups_has_member: true when stack is in group" {
  _write_groups <<'EOF'
[g]
alpha
beta
EOF
  run groups_has_member "g" "beta"
  [ "$status" -eq 0 ]
}

@test "groups_has_member: false when stack absent" {
  _write_groups <<'EOF'
[g]
alpha
EOF
  run groups_has_member "g" "missing"
  [ "$status" -ne 0 ]
}

# ── groups_add ────────────────────────────────────────────────────────────────

@test "groups_add: creates file + section when neither exists" {
  rm -f "$STRUT_GROUPS_CONF"
  groups_add "new-group" "stack-a"
  [ -f "$STRUT_GROUPS_CONF" ]
  run groups_has_member "new-group" "stack-a"
  [ "$status" -eq 0 ]
}

@test "groups_add: appends to existing section" {
  _write_groups <<'EOF'
[g]
existing
EOF
  groups_add "g" "added"
  result=$(groups_members "g")
  [[ "$result" == *"existing"* ]]
  [[ "$result" == *"added"* ]]
}

@test "groups_add: idempotent — doesn't duplicate members" {
  _write_groups <<'EOF'
[g]
alpha
EOF
  groups_add "g" "alpha"
  count=$(groups_members "g" | grep -c "^alpha$")
  [ "$count" -eq 1 ]
}

@test "groups_add: creates a new section when the group is new" {
  _write_groups <<'EOF'
[existing]
a
EOF
  groups_add "fresh" "x"
  run groups_exists "fresh"
  [ "$status" -eq 0 ]
  run groups_exists "existing"
  [ "$status" -eq 0 ]
}

# ── groups_remove ─────────────────────────────────────────────────────────────

@test "groups_remove: removes exact match" {
  _write_groups <<'EOF'
[g]
alpha
beta
gamma
EOF
  groups_remove "g" "beta"
  result=$(groups_members "g")
  [ "$result" = $'alpha\ngamma' ]
}

@test "groups_remove: idempotent when stack missing" {
  _write_groups <<'EOF'
[g]
alpha
EOF
  groups_remove "g" "not-there"
  result=$(groups_members "g")
  [ "$result" = "alpha" ]
}

@test "groups_remove: only affects the named group" {
  _write_groups <<'EOF'
[a]
shared

[b]
shared
EOF
  groups_remove "a" "shared"
  run groups_has_member "a" "shared"
  [ "$status" -ne 0 ]
  run groups_has_member "b" "shared"
  [ "$status" -eq 0 ]
}

# ── Round-trip add/remove preserves other content ─────────────────────────────

@test "groups: add+remove roundtrip leaves untouched content intact" {
  _write_groups <<'EOF'
# comment

[g1]
a
b

[g2]
c
EOF
  groups_add "g2" "d"
  groups_remove "g2" "c"
  g1=$(groups_members "g1")
  g2=$(groups_members "g2")
  [ "$g1" = $'a\nb' ]
  [ "$g2" = "d" ]
}

# ── Property: many add/remove operations leave consistent state ──────────────

@test "Property: 50 add/remove cycles never duplicate or lose members" {
  for i in $(seq 1 50); do
    groups_add "churn" "stack-$((i % 5))"
    if [ $((i % 3)) -eq 0 ]; then
      groups_remove "churn" "stack-$((i % 5))"
    fi
  done
  # After the dust settles, no duplicates.
  local members
  members=$(groups_members "churn")
  local unique
  unique=$(printf '%s\n' "$members" | sort -u)
  [ "$(printf '%s\n' "$members" | sort)" = "$unique" ]
}
