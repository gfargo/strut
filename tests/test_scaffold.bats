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
