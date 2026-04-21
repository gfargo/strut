#!/usr/bin/env bats
# ==================================================
# tests/test_recipes.bats — Scaffold recipe discovery + dispatch
# ==================================================
# Run:  bats tests/test_recipes.bats
# Covers: recipes_discover, recipes_has/dir_for, recipes_meta,
# recipes_list_text/json, end-to-end `strut scaffold --recipe` and
# `strut scaffold list`, plus official recipes that ship in tree.

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLI_ROOT
  CLI="$CLI_ROOT/strut"
  TEST_TMP="$(mktemp -d)"
  export PROJECT_ROOT="$TEST_TMP"
  export STRUT_HOME="$CLI_ROOT"
  mkdir -p "$PROJECT_ROOT/.strut/recipes"
  mkdir -p "$PROJECT_ROOT/stacks"
}

teardown() {
  rm -rf "$TEST_TMP"
  unset PROJECT_ROOT STRUT_HOME
}

_load_recipes() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/recipes.sh"
}

_make_recipe() {
  # _make_recipe <source-dir> <name> <description>
  local base="$1" name="$2" desc="$3"
  mkdir -p "$base/$name"
  cat > "$base/$name/recipe.conf" <<EOF
NAME=$name
DESCRIPTION=$desc
TAGS=test
EOF
  echo "stack: STACK_NAME_PLACEHOLDER" > "$base/$name/docker-compose.yml"
  echo "# org: YOUR_ORG" >> "$base/$name/docker-compose.yml"
}

# ── Discovery ─────────────────────────────────────────────────────────────────

@test "recipes_discover: finds user recipes" {
  _load_recipes
  _make_recipe "$PROJECT_ROOT/.strut/recipes" "custom-a" "Custom A"
  _make_recipe "$PROJECT_ROOT/.strut/recipes" "custom-b" "Custom B"
  recipes_discover
  recipes_has "custom-a"
  recipes_has "custom-b"
  [ "$(recipes_source_for custom-a)" = "user" ]
}

@test "recipes_discover: finds official recipes from STRUT_HOME" {
  _load_recipes
  recipes_discover
  # static-site, python-api, next-postgres ship in tree.
  recipes_has "static-site"
  recipes_has "python-api"
  recipes_has "next-postgres"
  [ "$(recipes_source_for static-site)" = "official" ]
}

@test "recipes_discover: user recipe overrides official of same name" {
  _load_recipes
  _make_recipe "$PROJECT_ROOT/.strut/recipes" "static-site" "My custom static-site"
  recipes_discover
  [ "$(recipes_source_for static-site)" = "user" ]
  [ "$(recipes_meta static-site DESCRIPTION)" = "My custom static-site" ]
}

@test "recipes_discover: silent when no recipe dirs exist" {
  _load_recipes
  # Point STRUT_HOME somewhere with no templates/recipes and clear user dir.
  local empty; empty="$(mktemp -d)"
  rm -rf "$PROJECT_ROOT/.strut/recipes"
  STRUT_HOME="$empty" recipes_discover
  [ "${#_STRUT_RECIPE_NAMES[@]}" -eq 0 ]
  rm -rf "$empty"
}

# ── Lookups ────────────────────────────────────────────────────────────────────

@test "recipes_dir_for: prints directory for a known recipe" {
  _load_recipes
  recipes_discover
  local dir
  dir="$(recipes_dir_for static-site)"
  [ -d "$dir" ]
  [ -f "$dir/recipe.conf" ]
}

@test "recipes_dir_for: exits non-zero for unknown recipe" {
  _load_recipes
  recipes_discover
  run recipes_dir_for nope-nope
  [ "$status" -ne 0 ]
}

@test "recipes_meta: reads DESCRIPTION from recipe.conf" {
  _load_recipes
  recipes_discover
  local desc
  desc="$(recipes_meta static-site DESCRIPTION)"
  [ -n "$desc" ]
}

@test "recipes_meta: returns empty for missing key (no error)" {
  _load_recipes
  recipes_discover
  run recipes_meta static-site NONEXISTENT_KEY
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── Listing ────────────────────────────────────────────────────────────────────

@test "recipes_list_text: renders a table with discovered recipes" {
  _load_recipes
  recipes_discover
  run recipes_list_text
  [ "$status" -eq 0 ]
  [[ "$output" == *"static-site"* ]]
  [[ "$output" == *"python-api"* ]]
}

@test "recipes_list_text: helpful empty message when no recipes" {
  _load_recipes
  local empty; empty="$(mktemp -d)"
  rm -rf "$PROJECT_ROOT/.strut/recipes"
  STRUT_HOME="$empty" recipes_discover
  run recipes_list_text
  [ "$status" -eq 0 ]
  [[ "$output" == *"No recipes found"* ]]
  rm -rf "$empty"
}

@test "recipes_list_json: emits valid JSON with recipe metadata" {
  _load_recipes
  recipes_discover
  run recipes_list_json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null 2>&1 || skip "python3 json.tool unavailable"
  [[ "$output" == *"\"name\""* ]]
  [[ "$output" == *"static-site"* ]]
  [[ "$output" == *"\"source\""* ]]
}

# ── End-to-end through the strut entrypoint ───────────────────────────────────

@test "strut scaffold list: prints discovered recipes" {
  run "$CLI" scaffold list
  [ "$status" -eq 0 ]
  [[ "$output" == *"static-site"* ]]
  [[ "$output" == *"python-api"* ]]
}

@test "strut scaffold list --json: emits JSON" {
  run "$CLI" scaffold list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"recipes\""* ]]
  [[ "$output" == *"static-site"* ]]
}

@test "strut scaffold <name> --recipe <recipe>: copies recipe + substitutes STACK_NAME" {
  run "$CLI" scaffold my-site --recipe static-site
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/stacks/my-site/docker-compose.yml" ]
  [ -f "$PROJECT_ROOT/stacks/my-site/caddy/Caddyfile" ]
  [ -f "$PROJECT_ROOT/stacks/my-site/README.md" ]
  # Should NOT copy recipe.conf itself
  [ ! -f "$PROJECT_ROOT/stacks/my-site/recipe.conf" ]
  # STACK_NAME_PLACEHOLDER should be substituted everywhere.
  run grep -r "STACK_NAME_PLACEHOLDER" "$PROJECT_ROOT/stacks/my-site"
  [ "$status" -ne 0 ]
  # my-site should appear in README.
  grep -q "my-site" "$PROJECT_ROOT/stacks/my-site/README.md"
}

@test "strut scaffold <name> --recipe <recipe>: YOUR_ORG substituted when DEFAULT_ORG set" {
  # Write a strut.conf so load_strut_config picks up DEFAULT_ORG.
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
DEFAULT_ORG=acme
EOF
  run "$CLI" scaffold my-api --recipe python-api
  [ "$status" -eq 0 ]
  run grep -r "YOUR_ORG" "$PROJECT_ROOT/stacks/my-api"
  [ "$status" -ne 0 ]
  grep -q "acme" "$PROJECT_ROOT/stacks/my-api/docker-compose.yml"
}

@test "strut scaffold <name> --recipe <unknown>: fails with clear message" {
  run "$CLI" scaffold bad-stack --recipe does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown recipe"* ]]
}

@test "strut scaffold <name> (no --recipe): still works (default scaffold)" {
  run "$CLI" scaffold plain-stack
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/stacks/plain-stack/docker-compose.yml" ]
  [ -f "$PROJECT_ROOT/stacks/plain-stack/.env.template" ]
}

@test "strut scaffold <name> --recipe=<recipe>: equals-form flag also works" {
  run "$CLI" scaffold my-site2 --recipe=static-site
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/stacks/my-site2/docker-compose.yml" ]
}

@test "strut scaffold: fails on unknown flag" {
  run "$CLI" scaffold foo --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag"* ]]
}

# ── Official recipes sanity ───────────────────────────────────────────────────

@test "official recipe static-site: has required files" {
  local dir="$CLI_ROOT/templates/recipes/static-site"
  [ -f "$dir/recipe.conf" ]
  [ -f "$dir/docker-compose.yml" ]
  [ -f "$dir/caddy/Caddyfile" ]
  [ -f "$dir/required_vars" ]
  [ -f "$dir/README.md" ]
}

@test "official recipe python-api: has required files" {
  local dir="$CLI_ROOT/templates/recipes/python-api"
  [ -f "$dir/recipe.conf" ]
  [ -f "$dir/docker-compose.yml" ]
  [ -f "$dir/app/Dockerfile" ]
  [ -f "$dir/app/main.py" ]
  [ -f "$dir/services.conf" ]
  [ -f "$dir/required_vars" ]
}

@test "official recipe next-postgres: has required files" {
  local dir="$CLI_ROOT/templates/recipes/next-postgres"
  [ -f "$dir/recipe.conf" ]
  [ -f "$dir/docker-compose.yml" ]
  [ -f "$dir/caddy/Caddyfile" ]
  [ -f "$dir/services.conf" ]
  [ -f "$dir/required_vars" ]
}

@test "every official recipe: required_vars appears in .env.template" {
  for dir in "$CLI_ROOT"/templates/recipes/*/; do
    local name; name="$(basename "$dir")"
    if [ -f "$dir/required_vars" ] && [ -f "$dir/.env.template" ]; then
      while IFS= read -r var; do
        [ -n "$var" ] || continue
        grep -qE "^${var}=" "$dir/.env.template" || {
          echo "recipe $name: required_var '$var' missing from .env.template" >&2
          return 1
        }
      done < "$dir/required_vars"
    fi
  done
}
