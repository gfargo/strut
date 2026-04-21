#!/usr/bin/env bats
# ==================================================
# tests/test_posture.bats — Tests for strut posture
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/output.sh"

  export REAL_CLI_ROOT="$CLI_ROOT"
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$CLI_ROOT/stacks"

  source "$REAL_CLI_ROOT/lib/cmd_posture.sh"
  posture_reset
}

teardown() {
  common_teardown
}

_make_stack() {
  local name="$1"
  mkdir -p "$CLI_ROOT/stacks/$name"
  cat > "$CLI_ROOT/stacks/$name/docker-compose.yml" <<'EOF'
services:
  app:
    image: example
EOF
}

_clean_env() {
  rm -f "$CLI_ROOT"/.env "$CLI_ROOT"/.*.env
}

# ── posture_emit + counters ───────────────────────────────────────────────────

@test "posture_emit: increments the right counter" {
  posture_emit pass secrets api "looks fine"
  posture_emit warn network api "port exposed"
  posture_emit fail runtime api "no mem limit"
  [ "$_POSTURE_PASS" -eq 1 ]
  [ "$_POSTURE_WARN" -eq 1 ]
  [ "$_POSTURE_FAIL" -eq 1 ]
  [ "${#_POSTURE_RESULTS[@]}" -eq 3 ]
}

@test "posture_reset: clears all buffers" {
  posture_emit fail secrets api "x"
  posture_reset
  [ "$_POSTURE_FAIL" -eq 0 ]
  [ "${#_POSTURE_RESULTS[@]}" -eq 0 ]
}

# ── check_placeholder_secrets ─────────────────────────────────────────────────

@test "check_placeholder_secrets: pass when no placeholders" {
  _clean_env
  cat > "$CLI_ROOT/.env" <<'EOF'
POSTGRES_PASSWORD=s3cret-real-value
API_KEY=sk_live_abc123xyz
EOF
  check_placeholder_secrets mystack
  [ "$_POSTURE_PASS" -eq 1 ]
  [ "$_POSTURE_FAIL" -eq 0 ]
}

@test "check_placeholder_secrets: fail when value is 'changeme'" {
  _clean_env
  cat > "$CLI_ROOT/.env" <<'EOF'
POSTGRES_PASSWORD=changeme
EOF
  check_placeholder_secrets mystack
  [ "$_POSTURE_FAIL" -eq 1 ]
}

@test "check_placeholder_secrets: fail when value is 'password'" {
  _clean_env
  cat > "$CLI_ROOT/.env" <<'EOF'
DB_PASS=password
EOF
  check_placeholder_secrets mystack
  [ "$_POSTURE_FAIL" -eq 1 ]
}

@test "check_placeholder_secrets: case-insensitive match" {
  _clean_env
  cat > "$CLI_ROOT/.env" <<'EOF'
FOO=CHANGEME
EOF
  check_placeholder_secrets mystack
  [ "$_POSTURE_FAIL" -eq 1 ]
}

@test "check_placeholder_secrets: strips quotes before comparing" {
  _clean_env
  cat > "$CLI_ROOT/.env" <<'EOF'
FOO="changeme"
EOF
  check_placeholder_secrets mystack
  [ "$_POSTURE_FAIL" -eq 1 ]
}

@test "check_placeholder_secrets: ignores comments and blank lines" {
  _clean_env
  cat > "$CLI_ROOT/.env" <<'EOF'
# This is a comment

VALID_KEY=real-value
EOF
  check_placeholder_secrets mystack
  [ "$_POSTURE_PASS" -eq 1 ]
}

# ── check_env_in_git ──────────────────────────────────────────────────────────

@test "check_env_in_git: passes when not a git repo" {
  check_env_in_git mystack
  [ "$_POSTURE_PASS" -eq 1 ]
}

@test "check_env_in_git: fails when .env is tracked" {
  ( cd "$CLI_ROOT" && git init -q && git config user.email t@t && git config user.name t )
  echo "SECRET=value" > "$CLI_ROOT/.env"
  ( cd "$CLI_ROOT" && git add .env && git commit -q -m "bad" )
  check_env_in_git mystack
  [ "$_POSTURE_FAIL" -eq 1 ]
}

@test "check_env_in_git: passes when .env is gitignored" {
  ( cd "$CLI_ROOT" && git init -q && git config user.email t@t && git config user.name t )
  echo ".env" > "$CLI_ROOT/.gitignore"
  echo "SECRET=value" > "$CLI_ROOT/.env"
  ( cd "$CLI_ROOT" && git add .gitignore && git commit -q -m "gitignore" )
  check_env_in_git mystack
  [ "$_POSTURE_PASS" -eq 1 ]
}

# ── check_compose_ports ───────────────────────────────────────────────────────

@test "check_compose_ports: warns when port published to 0.0.0.0" {
  mkdir -p "$CLI_ROOT/stacks/api"
  cat > "$CLI_ROOT/stacks/api/docker-compose.yml" <<'EOF'
services:
  app:
    ports:
      - "8080:8080"
EOF
  check_compose_ports api
  [ "$_POSTURE_WARN" -eq 1 ]
}

@test "check_compose_ports: passes when bound to 127.0.0.1" {
  mkdir -p "$CLI_ROOT/stacks/api"
  cat > "$CLI_ROOT/stacks/api/docker-compose.yml" <<'EOF'
services:
  app:
    ports:
      - "127.0.0.1:8080:8080"
EOF
  check_compose_ports api
  [ "$_POSTURE_PASS" -eq 1 ]
}

@test "check_compose_ports: passes when no ports declared" {
  mkdir -p "$CLI_ROOT/stacks/api"
  cat > "$CLI_ROOT/stacks/api/docker-compose.yml" <<'EOF'
services:
  app:
    image: x
EOF
  check_compose_ports api
  [ "$_POSTURE_PASS" -eq 1 ]
}

@test "check_compose_ports: passes when compose file missing" {
  mkdir -p "$CLI_ROOT/stacks/nocompose"
  check_compose_ports nocompose
  [ "$_POSTURE_PASS" -eq 1 ]
}

# ── check_resource_limits ─────────────────────────────────────────────────────

@test "check_resource_limits: warns when no mem_limit defined" {
  mkdir -p "$CLI_ROOT/stacks/api"
  cat > "$CLI_ROOT/stacks/api/docker-compose.yml" <<'EOF'
services:
  app:
    image: x
EOF
  check_resource_limits api
  [ "$_POSTURE_WARN" -eq 1 ]
}

@test "check_resource_limits: passes when mem_limit set" {
  mkdir -p "$CLI_ROOT/stacks/api"
  cat > "$CLI_ROOT/stacks/api/docker-compose.yml" <<'EOF'
services:
  app:
    image: x
    mem_limit: 512m
EOF
  check_resource_limits api
  [ "$_POSTURE_PASS" -eq 1 ]
}

# ── check_required_vars ───────────────────────────────────────────────────────

@test "check_required_vars: passes when no required_vars file" {
  mkdir -p "$CLI_ROOT/stacks/api"
  check_required_vars api
  [ "$_POSTURE_PASS" -eq 1 ]
}

@test "check_required_vars: fails when required var missing from env" {
  mkdir -p "$CLI_ROOT/stacks/api"
  echo "POSTGRES_PASSWORD" > "$CLI_ROOT/stacks/api/required_vars"
  _clean_env
  echo "OTHER=value" > "$CLI_ROOT/.env"
  check_required_vars api
  [ "$_POSTURE_FAIL" -eq 1 ]
}

@test "check_required_vars: passes when all required vars present" {
  mkdir -p "$CLI_ROOT/stacks/api"
  printf 'POSTGRES_PASSWORD\nAPI_KEY\n' > "$CLI_ROOT/stacks/api/required_vars"
  _clean_env
  cat > "$CLI_ROOT/.env" <<'EOF'
POSTGRES_PASSWORD=real
API_KEY=sk_live
EOF
  check_required_vars api
  [ "$_POSTURE_PASS" -eq 1 ]
}

# ── cmd_posture entrypoint ────────────────────────────────────────────────────

@test "cmd_posture: no stacks directory fails" {
  rm -rf "$CLI_ROOT/stacks"
  run cmd_posture
  [ "$status" -ne 0 ]
  [[ "$output" == *"No stacks"* ]]
}

@test "cmd_posture: unknown flag fails" {
  _make_stack api
  run cmd_posture --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag"* ]]
}

@test "cmd_posture: --help prints usage" {
  run cmd_posture --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"posture"* ]]
}

@test "cmd_posture: invalid --fail-on level fails" {
  _make_stack api
  run cmd_posture --fail-on bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --fail-on"* ]]
}

@test "cmd_posture: unknown category fails" {
  _make_stack api
  run cmd_posture --category xyz
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown category"* ]]
}

@test "cmd_posture: text output runs across all stacks" {
  _make_stack api
  _make_stack worker
  _clean_env
  run cmd_posture
  # Text mode: may exit 0 or 1 depending on default policies
  [[ "$output" == *"Posture check"* ]]
  [[ "$output" == *"passed"* ]]
}

@test "cmd_posture: json mode produces structured output" {
  _make_stack api
  _clean_env
  run cmd_posture --json
  [[ "$output" == *'"timestamp":'* ]]
  [[ "$output" == *'"findings":'* ]]
  [[ "$output" == *'"summary":'* ]]
  [[ "$output" == *'"pass":'* ]]
}

@test "cmd_posture: --stack filter limits to one stack" {
  _make_stack api
  _make_stack worker
  _clean_env
  run cmd_posture --stack api --json
  [[ "$output" == *'"stack":"api"'* ]]
  [[ "$output" != *'"stack":"worker"'* ]]
}

@test "cmd_posture: --category secrets only runs secrets checks" {
  _make_stack api
  _clean_env
  run cmd_posture --category secrets --json
  [[ "$output" == *'"category":"secrets"'* ]]
  [[ "$output" != *'"category":"network"'* ]]
}

@test "cmd_posture: exit 1 when a placeholder secret is found" {
  _make_stack api
  _clean_env
  echo "POSTGRES_PASSWORD=changeme" > "$CLI_ROOT/.env"
  run cmd_posture
  [ "$status" -eq 1 ]
}

@test "cmd_posture: --fail-on warn exits 1 on warnings" {
  _make_stack api
  # Compose with 0.0.0.0 port → warn; no failing conditions
  cat > "$CLI_ROOT/stacks/api/docker-compose.yml" <<'EOF'
services:
  app:
    image: x
    ports:
      - "8080:8080"
    mem_limit: 128m
EOF
  _clean_env
  echo "REAL=value" > "$CLI_ROOT/.env"
  run cmd_posture --fail-on warn
  [ "$status" -eq 1 ]
}

@test "cmd_posture: default fail-on level ignores warnings" {
  _make_stack api
  cat > "$CLI_ROOT/stacks/api/docker-compose.yml" <<'EOF'
services:
  app:
    image: x
    ports:
      - "8080:8080"
    mem_limit: 128m
EOF
  _clean_env
  echo "REAL=value" > "$CLI_ROOT/.env"
  run cmd_posture
  [ "$status" -eq 0 ]
}
