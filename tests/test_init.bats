#!/usr/bin/env bats
# ==================================================
# tests/test_init.bats — Property tests for strut init
# ==================================================
# Property 15: Init flags propagate to generated strut.conf
# Validates: Requirements 13.5, 13.6
#
# Run:  bats tests/test_init.bats

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  # Override fail() to not exit the test runner
  fail() { echo "$1" >&2; return 1; }

  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/cmd_init.sh"

  export STRUT_HOME="$CLI_ROOT"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── Helper: generate random alphanumeric string ──────────────────────────────

_rand_str() {
  local len="${1:-8}"
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$len" 2>/dev/null || true
}

# ── Property 15: Init flags propagate to generated strut.conf ────────────────
# Feature: ch-deploy-modularization, Property 15: Init flags propagate to generated strut.conf
# Validates: Requirements 13.5, 13.6

@test "Property 15: --registry flag propagates to strut.conf (4 valid types)" {
  local types=("ghcr" "dockerhub" "ecr" "none")
  for reg_type in "${types[@]}"; do
    local project_dir="$TEST_TMP/init_reg_$reg_type"
    mkdir -p "$project_dir"

    (
      cd "$project_dir"
      cmd_init --registry "$reg_type"
    )

    # strut.conf should contain an active (uncommented) REGISTRY_TYPE line
    grep -q "^REGISTRY_TYPE=$reg_type" "$project_dir/strut.conf"
  done
}

@test "Property 15: --org flag propagates to strut.conf" {
  local project_dir="$TEST_TMP/init_org"
  mkdir -p "$project_dir"

  (
    cd "$project_dir"
    cmd_init --org "my-cool-org"
  )

  grep -q "^DEFAULT_ORG=my-cool-org" "$project_dir/strut.conf"
}

@test "Property 15: both --registry and --org propagate together" {
  local project_dir="$TEST_TMP/init_both"
  mkdir -p "$project_dir"

  (
    cd "$project_dir"
    cmd_init --registry ecr --org "acme-corp"
  )

  grep -q "^REGISTRY_TYPE=ecr" "$project_dir/strut.conf"
  grep -q "^DEFAULT_ORG=acme-corp" "$project_dir/strut.conf"
}

@test "Property 15: random org names propagate correctly — 100 iterations" {
  for i in $(seq 1 100); do
    local org_name="org-$(_rand_str 6)-$i"
    local project_dir="$TEST_TMP/init_rand_$i"
    mkdir -p "$project_dir"

    (
      cd "$project_dir"
      cmd_init --org "$org_name"
    )

    grep -q "^DEFAULT_ORG=$org_name" "$project_dir/strut.conf"
  done
}

@test "Property 15: random registry+org combinations — 100 iterations" {
  local types=("ghcr" "dockerhub" "ecr" "none")
  for i in $(seq 1 100); do
    local reg_type="${types[$(( RANDOM % 4 ))]}"
    local org_name="org-$(_rand_str 5)-$i"
    local project_dir="$TEST_TMP/init_combo_$i"
    mkdir -p "$project_dir"

    (
      cd "$project_dir"
      cmd_init --registry "$reg_type" --org "$org_name"
    )

    grep -q "^REGISTRY_TYPE=$reg_type" "$project_dir/strut.conf"
    grep -q "^DEFAULT_ORG=$org_name" "$project_dir/strut.conf"
  done
}

# ── Unit tests ────────────────────────────────────────────────────────────────

@test "init: creates stacks/ directory" {
  local project_dir="$TEST_TMP/init_stacks"
  mkdir -p "$project_dir"

  (cd "$project_dir" && cmd_init)

  [ -d "$project_dir/stacks" ]
}

@test "init: creates strut.conf from template" {
  local project_dir="$TEST_TMP/init_conf"
  mkdir -p "$project_dir"

  (cd "$project_dir" && cmd_init)

  [ -f "$project_dir/strut.conf" ]
  # Should contain commented defaults from template
  grep -q "REGISTRY_TYPE" "$project_dir/strut.conf"
  grep -q "DEFAULT_BRANCH" "$project_dir/strut.conf"
}

@test "init: creates .gitignore with correct exclusions" {
  local project_dir="$TEST_TMP/init_gitignore"
  mkdir -p "$project_dir"

  (cd "$project_dir" && cmd_init)

  [ -f "$project_dir/.gitignore" ]
  grep -q ".env" "$project_dir/.gitignore"
  grep -q "backups/" "$project_dir/.gitignore"
  grep -q "data/" "$project_dir/.gitignore"
  grep -q ".rollback/" "$project_dir/.gitignore"
  grep -q ".bluegreen" "$project_dir/.gitignore"
}

@test "init: preserves existing populated .gitignore and appends missing strut rules under marker" {
  local project_dir="$TEST_TMP/init_gitignore_preserve"
  mkdir -p "$project_dir"
  printf 'node_modules/\ndist/\n# my own comment\n' > "$project_dir/.gitignore"

  (cd "$project_dir" && cmd_init)

  # Original user content must survive untouched
  grep -qxF "node_modules/" "$project_dir/.gitignore"
  grep -qxF "dist/" "$project_dir/.gitignore"
  grep -qxF "# my own comment" "$project_dir/.gitignore"

  # Missing strut rules appended under the managed marker
  grep -qxF "# strut — managed rules" "$project_dir/.gitignore"
  grep -qxF ".env" "$project_dir/.gitignore"
  grep -qxF ".env.*" "$project_dir/.gitignore"
  grep -qxF "!.env.template" "$project_dir/.gitignore"
  grep -qxF "backups/" "$project_dir/.gitignore"
  grep -qxF "data/" "$project_dir/.gitignore"
  grep -qxF ".rollback/" "$project_dir/.gitignore"
  grep -qxF ".bluegreen" "$project_dir/.gitignore"
}

@test "init: does not duplicate strut rules already present as bare lines" {
  local project_dir="$TEST_TMP/init_gitignore_no_dupe"
  mkdir -p "$project_dir"
  printf 'node_modules/\n.env\n.env.*\n!.env.template\nbackups/\ndata/\n.rollback/\n.bluegreen\n' > "$project_dir/.gitignore"
  local before
  before="$(cat "$project_dir/.gitignore")"

  (cd "$project_dir" && cmd_init)

  # No marker block added since every strut rule was already present
  run grep -qxF "# strut — managed rules" "$project_dir/.gitignore"
  [ "$status" -ne 0 ]

  # File content is byte-for-byte unchanged
  [ "$(cat "$project_dir/.gitignore")" = "$before" ]
}

@test "init: .gitignore is idempotent — unchanged on repeated invocations once marker exists" {
  local project_dir="$TEST_TMP/init_gitignore_idempotent"
  mkdir -p "$project_dir"
  printf 'node_modules/\n\n# strut — managed rules\n.env\n.env.*\n!.env.template\nbackups/\ndata/\n.rollback/\n.bluegreen\n' > "$project_dir/.gitignore"

  (cd "$project_dir" && cmd_init)
  local checksum_after_first
  checksum_after_first="$(md5sum "$project_dir/.gitignore" | awk '{print $1}')"

  rm -f "$project_dir/strut.conf"
  (cd "$project_dir" && cmd_init)
  local checksum_after_second
  checksum_after_second="$(md5sum "$project_dir/.gitignore" | awk '{print $1}')"

  [ "$checksum_after_first" = "$checksum_after_second" ]
}

@test "init: generated .gitignore keeps git clean from listing .rollback/ and .bluegreen (OSS-415)" {
  local project_dir="$TEST_TMP/init_gitignore_clean_guard"
  mkdir -p "$project_dir"

  (cd "$project_dir" && cmd_init)

  git -C "$project_dir" init -q
  mkdir -p "$project_dir/.rollback"
  echo '{}' > "$project_dir/.rollback/snapshot.json"
  touch "$project_dir/.bluegreen"

  run git -C "$project_dir" clean -fdn
  [ "$status" -eq 0 ]
  [[ "$output" != *".rollback"* ]]
  [[ "$output" != *".bluegreen"* ]]

  run git -C "$project_dir" clean -fd
  [ "$status" -eq 0 ]
  [ -f "$project_dir/.rollback/snapshot.json" ]
  [ -f "$project_dir/.bluegreen" ]
}

@test "init: aborts if strut.conf already exists" {
  local project_dir="$TEST_TMP/init_exists"
  mkdir -p "$project_dir"
  echo "# existing" > "$project_dir/strut.conf"

  run bash -c "cd '$project_dir' && source '$CLI_ROOT/lib/utils.sh' && source '$CLI_ROOT/lib/config.sh' && source '$CLI_ROOT/lib/cmd_init.sh' && export STRUT_HOME='$CLI_ROOT' && cmd_init"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already initialized"* ]]
}

@test "init: rejects invalid registry type" {
  local project_dir="$TEST_TMP/init_bad_reg"
  mkdir -p "$project_dir"

  run bash -c "cd '$project_dir' && source '$CLI_ROOT/lib/utils.sh' && source '$CLI_ROOT/lib/config.sh' && source '$CLI_ROOT/lib/cmd_init.sh' && export STRUT_HOME='$CLI_ROOT' && cmd_init --registry invalid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported registry type"* ]]
}

@test "init: no flags produces all-commented strut.conf" {
  local project_dir="$TEST_TMP/init_noflags"
  mkdir -p "$project_dir"

  (cd "$project_dir" && cmd_init)

  # REGISTRY_TYPE should still be commented (not active)
  run grep "^REGISTRY_TYPE=" "$project_dir/strut.conf"
  [ "$status" -ne 0 ]

  # DEFAULT_ORG should still be commented
  run grep "^DEFAULT_ORG=" "$project_dir/strut.conf"
  [ "$status" -ne 0 ]
}
