#!/usr/bin/env bats
# ==================================================
# tests/test_scaffold.bats — Scaffold property tests
# ==================================================
# Property 10: Scaffold substitutes DEFAULT_ORG into generated templates
# Property 11: Scaffold required_vars is a subset of env.template variables
#
# Run:  bats tests/test_scaffold.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Source config.sh for DEFAULT_ORG support
  source "$CLI_ROOT/lib/config.sh"

  export PROJECT_ROOT="$TEST_TMP"
  export STRUT_HOME="$CLI_ROOT"

  # Source cmd_scaffold from its lib module
  source "$CLI_ROOT/lib/cmd_scaffold.sh"
}

teardown() {
  common_teardown
}

# ── Property 10: Scaffold substitutes DEFAULT_ORG ─────────────────────────────
# Feature: ch-deploy-modularization, Property 10: Scaffold substitutes DEFAULT_ORG into generated templates

@test "Property 10: DEFAULT_ORG=acme-corp substitutes into docker-compose.yml" {
  export DEFAULT_ORG="acme-corp"
  cmd_scaffold "test-stack"

  local compose="$TEST_TMP/stacks/test-stack/docker-compose.yml"
  [ -f "$compose" ]
  # YOUR_ORG should be replaced with acme-corp
  run grep "YOUR_ORG" "$compose"
  [ "$status" -ne 0 ]  # no YOUR_ORG remaining
  run grep "acme-corp" "$compose"
  [ "$status" -eq 0 ]  # acme-corp present
}

@test "Property 10: DEFAULT_ORG unset leaves YOUR_ORG placeholder" {
  unset DEFAULT_ORG
  export DEFAULT_ORG=""
  cmd_scaffold "test-stack"

  local compose="$TEST_TMP/stacks/test-stack/docker-compose.yml"
  [ -f "$compose" ]
  run grep "YOUR_ORG" "$compose"
  [ "$status" -eq 0 ]  # YOUR_ORG still present
}

# ── Regression: warn when YOUR_ORG survives scaffold ─────────────────────────
# Docker rejects uppercase repository names on deploy. When DEFAULT_ORG is
# unset and the selected recipe has `image: YOUR_ORG/...:latest`, scaffold
# must emit a warning so the user fixes it before `strut deploy`.

@test "scaffold: recipe with YOUR_ORG in image: emits warning when DEFAULT_ORG unset" {
  source "$CLI_ROOT/lib/recipes.sh"
  unset DEFAULT_ORG
  export DEFAULT_ORG=""
  run cmd_scaffold "py-stack" --recipe python-api
  [ "$status" -eq 0 ]
  [[ "$output" == *"YOUR_ORG"* ]]
  [[ "$output" == *"repository name must be lowercase"* ]]
  [[ "$output" == *"docker-compose.yml"* ]]
}

@test "scaffold: recipe with DEFAULT_ORG set produces no uppercase tokens in image: fields" {
  source "$CLI_ROOT/lib/recipes.sh"
  export DEFAULT_ORG="acme-corp"
  run cmd_scaffold "clean-stack" --recipe python-api
  [ "$status" -eq 0 ]

  local compose="$TEST_TMP/stacks/clean-stack/docker-compose.yml"
  [ -f "$compose" ]

  # Every image: line must be entirely lowercase (digits, lowercase letters,
  # and these separators only: /  :  -  _  .). Any uppercase in an image: line
  # would be rejected by Docker at deploy time.
  run grep -E '^\s*image:.*[A-Z]' "$compose"
  [ "$status" -ne 0 ]

  # No warning should fire in the happy path
  run cmd_scaffold "clean-stack-2" --recipe python-api
  [[ "$output" != *"repository name must be lowercase"* ]]
}

@test "Property 10: random org names substitute correctly — 20 iterations" {
  for i in $(seq 1 20); do
    local org_name="org-${RANDOM}-${i}"
    export DEFAULT_ORG="$org_name"

    local stack_name="stack-${RANDOM}-${i}"
    cmd_scaffold "$stack_name"

    local compose="$TEST_TMP/stacks/$stack_name/docker-compose.yml"
    [ -f "$compose" ]

    # No YOUR_ORG remaining
    run grep "YOUR_ORG" "$compose"
    [ "$status" -ne 0 ]

    # Org name present
    run grep "$org_name" "$compose"
    [ "$status" -eq 0 ]
  done
}

# ── Property 11: required_vars is a subset of env.template ────────────────────
# Feature: ch-deploy-modularization, Property 11: Scaffold required_vars is a subset of env.template variables

@test "Property 11: every required_var appears in env.template" {
  cmd_scaffold "test-stack"

  local req_vars="$TEST_TMP/stacks/test-stack/required_vars"
  local env_tmpl="$TEST_TMP/stacks/test-stack/.env.template"

  [ -f "$req_vars" ]
  [ -f "$env_tmpl" ]

  # Extract variable names from env.template (lines matching KEY=value)
  local env_keys
  env_keys=$(grep -E '^[A-Z_]+=.' "$env_tmpl" | sed 's/=.*//')

  # Every line in required_vars must appear in env_keys
  while IFS= read -r var; do
    [ -z "$var" ] && continue
    echo "$env_keys" | grep -qx "$var" || {
      echo "FAIL: $var in required_vars but not in .env.template"
      return 1
    }
  done < "$req_vars"
}

@test "Property 11: required_vars is non-empty" {
  cmd_scaffold "test-stack"

  local req_vars="$TEST_TMP/stacks/test-stack/required_vars"
  [ -f "$req_vars" ]
  [ -s "$req_vars" ]  # non-empty
}

# ── Hostile-character property tests ─────────────────────────────────────────
# strut #252: `_scaffold_substitute` interpolates $new_name / $DEFAULT_ORG
# unescaped into a `sed s/.../.../` replacement (lib/cmd_scaffold.sh) — values
# containing the sed delimiter (/), `&`, or `\` corrupt the expression, and the
# `2>/dev/null` on the sed pipeline hid the failure, silently leaving
# STACK_NAME_PLACEHOLDER/YOUR_ORG un-substituted (e.g. `cmd_scaffold "weird/name"`
# left `STACK_NAME_PLACEHOLDER` in .gitignore). Each hostile value must
# substitute cleanly instead.

_hostile_names() {
  printf '%s\n' \
    'has space' \
    'slash/org' \
    'amp&persand' \
    'semi;colon' \
    "quo'te" \
    'dollar$sign' \
    'back`tick'
}

@test "scaffold: hostile-character DEFAULT_ORG substitutes cleanly, no STACK_NAME_PLACEHOLDER/YOUR_ORG left" {
  local i=0
  while IFS= read -r org_name; do
    i=$((i + 1))
    export DEFAULT_ORG="$org_name"
    local stack_name="hostile-org-$i"

    cmd_scaffold "$stack_name"

    local target="$TEST_TMP/stacks/$stack_name"
    [ -f "$target/docker-compose.yml" ]

    run grep -r "STACK_NAME_PLACEHOLDER" "$target"
    [ "$status" -ne 0 ] || { echo "FAIL: STACK_NAME_PLACEHOLDER survived for org '$org_name'"; return 1; }

    run grep -r "YOUR_ORG" "$target"
    [ "$status" -ne 0 ] || { echo "FAIL: YOUR_ORG survived for org '$org_name'"; return 1; }

    grep -qF "$org_name" "$target/docker-compose.yml" || {
      echo "FAIL: org name '$org_name' not found substituted in docker-compose.yml"
      return 1
    }
  done < <(_hostile_names)
}

@test "scaffold: hostile-character stack name substitutes cleanly, no STACK_NAME_PLACEHOLDER left" {
  local i=0
  while IFS= read -r name_part; do
    i=$((i + 1))
    local stack_name="hostile-$i-${name_part}"

    cmd_scaffold "$stack_name"

    local target="$TEST_TMP/stacks/$stack_name"
    [ -f "$target/docker-compose.yml" ]

    run grep -r "STACK_NAME_PLACEHOLDER" "$target"
    [ "$status" -ne 0 ] || { echo "FAIL: STACK_NAME_PLACEHOLDER survived for stack name '$stack_name'"; return 1; }
  done < <(_hostile_names)
}

# ── Unit tests ────────────────────────────────────────────────────────────────

@test "scaffold: generates services.conf from template" {
  cmd_scaffold "test-stack"

  local svc_conf="$TEST_TMP/stacks/test-stack/services.conf"
  [ -f "$svc_conf" ]
  # Should contain the convention documentation
  run grep "_PORT" "$svc_conf"
  [ "$status" -eq 0 ]
  run grep "DB_" "$svc_conf"
  [ "$status" -eq 0 ]
}

@test "scaffold: fails if stack already exists" {
  mkdir -p "$TEST_TMP/stacks/test-stack"
  run cmd_scaffold "test-stack"
  [[ "$output" == *"already exists"* ]]
}

@test "scaffold: creates all expected files" {
  cmd_scaffold "test-stack"

  local target="$TEST_TMP/stacks/test-stack"
  [ -f "$target/docker-compose.yml" ]
  [ -f "$target/.env.template" ]
  [ -f "$target/services.conf" ]
  [ -f "$target/required_vars" ]
  [ -f "$target/backup.conf" ]
  [ -f "$target/nginx/nginx.conf" ]
  [ -d "$target/sql/init" ]
}

@test "scaffold: no c6-hub or climate-hub references in generated files" {
  export DEFAULT_ORG="test-org"
  cmd_scaffold "test-stack"

  local target="$TEST_TMP/stacks/test-stack"
  run grep -r "c6-hub" "$target"
  [ "$status" -ne 0 ]
  run grep -r "climate-hub" "$target"
  [ "$status" -ne 0 ]
  run grep -r "climate_hub" "$target"
  [ "$status" -ne 0 ]
}

# ── Proxy-aware scaffold tests ────────────────────────────────────────────────
# Feature: pluggable-reverse-proxy, Requirements 3.1, 3.2

@test "scaffold: REVERSE_PROXY=nginx creates nginx directory with nginx.conf and conf.d" {
  export REVERSE_PROXY="nginx"
  cmd_scaffold "nginx-stack"

  local target="$TEST_TMP/stacks/nginx-stack"
  [ -d "$target/nginx" ]
  [ -d "$target/nginx/conf.d" ]
  [ -f "$target/nginx/nginx.conf" ]
  [ ! -d "$target/caddy" ]
}

@test "scaffold: REVERSE_PROXY=caddy creates caddy directory with Caddyfile" {
  export REVERSE_PROXY="caddy"
  cmd_scaffold "caddy-stack"

  local target="$TEST_TMP/stacks/caddy-stack"
  [ -d "$target/caddy" ]
  [ -f "$target/caddy/Caddyfile" ]
  grep -q "reverse_proxy" "$target/caddy/Caddyfile"
  [ ! -d "$target/nginx" ]
}

@test "scaffold: default REVERSE_PROXY (unset) creates nginx directory" {
  unset REVERSE_PROXY
  cmd_scaffold "default-proxy-stack"

  local target="$TEST_TMP/stacks/default-proxy-stack"
  [ -d "$target/nginx" ]
  [ -f "$target/nginx/nginx.conf" ]
  [ ! -d "$target/caddy" ]
}

# ── Recipe library consistency ────────────────────────────────────────────────
# Guards every official recipe (not just the default scaffold): each must carry
# NAME + DESCRIPTION in recipe.conf, a docker-compose.yml, and a required_vars
# file whose entries all appear as keys in .env.template.
@test "recipes: every official recipe is internally consistent" {
  local recipes_dir="$CLI_ROOT/templates/recipes"
  [ -d "$recipes_dir" ]

  local recipe
  for recipe in "$recipes_dir"/*/; do
    [ -d "$recipe" ] || continue
    local name
    name=$(basename "$recipe")

    [ -f "$recipe/recipe.conf" ]        || { echo "FAIL: $name missing recipe.conf"; return 1; }
    [ -f "$recipe/docker-compose.yml" ] || { echo "FAIL: $name missing docker-compose.yml"; return 1; }
    grep -qE '^NAME=.'        "$recipe/recipe.conf" || { echo "FAIL: $name recipe.conf missing NAME"; return 1; }
    grep -qE '^DESCRIPTION=.'  "$recipe/recipe.conf" || { echo "FAIL: $name recipe.conf missing DESCRIPTION"; return 1; }

    # required_vars (if present) must be a subset of .env.template keys.
    if [ -f "$recipe/required_vars" ]; then
      [ -f "$recipe/.env.template" ] || { echo "FAIL: $name has required_vars but no .env.template"; return 1; }
      local env_keys
      env_keys=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$recipe/.env.template" | sed 's/=.*//')
      local var
      while IFS= read -r var; do
        [ -z "$var" ] && continue
        echo "$env_keys" | grep -qx "$var" || {
          echo "FAIL: $name — required_var '$var' not in .env.template"
          return 1
        }
      done < "$recipe/required_vars"
    fi
  done
}

# ── Data-safety: recipe .gitignore covers env-indirected bind mounts ─────────
# strut #213: recipe data dirs are bind-mounted via `${VAR:-./default}` (or a
# bare `${VAR}` with the default only in .env.template), not literal `- ./path`
# lines. `.gitignore` must contain the resolved, concrete data-dir entry so
# `strut deploy`'s `git clean -fd` on the VPS can't delete user data.

@test "scaffold --recipe jellyfin: .gitignore contains resolved media/ entry" {
  source "$CLI_ROOT/lib/recipes.sh"
  cmd_scaffold "jf-stack" --recipe jellyfin
  grep -qxF "media/" "$TEST_TMP/stacks/jf-stack/.gitignore"
}

@test "scaffold --recipe audiobookshelf: .gitignore contains resolved audiobooks/ and podcasts/ entries" {
  source "$CLI_ROOT/lib/recipes.sh"
  cmd_scaffold "abs-stack" --recipe audiobookshelf
  grep -qxF "audiobooks/" "$TEST_TMP/stacks/abs-stack/.gitignore"
  grep -qxF "podcasts/" "$TEST_TMP/stacks/abs-stack/.gitignore"
}

@test "scaffold --recipe paperless-ngx: .gitignore contains resolved consume/ entry" {
  source "$CLI_ROOT/lib/recipes.sh"
  cmd_scaffold "paperless-stack" --recipe paperless-ngx
  grep -qxF "consume/" "$TEST_TMP/stacks/paperless-stack/.gitignore"
}

@test "scaffold --recipe immich: .gitignore contains resolved immich-library/ entry (bare \${VAR}, default from .env.template)" {
  source "$CLI_ROOT/lib/recipes.sh"
  cmd_scaffold "immich-stack" --recipe immich
  grep -qxF "immich-library/" "$TEST_TMP/stacks/immich-stack/.gitignore"
}

@test "scaffold --recipe: git clean -nd finds nothing after simulated first Docker run" {
  source "$CLI_ROOT/lib/recipes.sh"
  cmd_scaffold "immich-clean" --recipe immich

  local target="$TEST_TMP/stacks/immich-clean"
  (
    cd "$target"
    git init -q
    git -c user.email=test@example.com -c user.name=test add -A
    git -c user.email=test@example.com -c user.name=test commit -q -m init
    mkdir -p immich-library
    echo "fake-upload" > immich-library/photo.jpg
    [ -z "$(git clean -nd)" ]
  )
}

@test "scaffold --recipe next-postgres: .gitignore does not gain a caddy/ entry (checked-in config, not env-indirected)" {
  source "$CLI_ROOT/lib/recipes.sh"
  cmd_scaffold "next-stack" --recipe next-postgres
  run grep -xF "caddy/" "$TEST_TMP/stacks/next-stack/.gitignore"
  [ "$status" -ne 0 ]
}

@test "scaffold --recipe static-site: .gitignore does not gain caddy/ or public/ entries (checked-in config/content)" {
  source "$CLI_ROOT/lib/recipes.sh"
  run cmd_scaffold "static-stack" --recipe static-site
  [ "$status" -eq 0 ]
  [[ "$output" != *"bind-mounts data inside the stack dir"* ]]

  local gi="$TEST_TMP/stacks/static-stack/.gitignore"
  run grep -xF "caddy/" "$gi"
  [ "$status" -ne 0 ]
  run grep -xF "public/" "$gi"
  [ "$status" -ne 0 ]
}
