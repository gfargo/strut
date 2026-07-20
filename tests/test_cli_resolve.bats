#!/usr/bin/env bats
# ==================================================
# tests/test_cli_resolve.bats — Tests for resolve_env_file, resolve_compose_cmd
# ==================================================
# Run:  bats tests/test_cli_resolve.bats
# Covers: env file path resolution, compose command construction

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLI_ROOT
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_cli_functions() {
  # Source just the functions we need without running main
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/docker.sh"
  # Override fail() to not exit
  fail() { echo "$1" >&2; return 1; }

  # Import resolve_env_file and resolve_compose_cmd from strut
  # These are defined as functions in strut, extract them
  eval "$(sed -n '/^resolve_env_file()/,/^}/p' "$CLI_ROOT/strut")"
  eval "$(sed -n '/^resolve_compose_cmd()/,/^}/p' "$CLI_ROOT/strut")"
}

# ── resolve_env_file ──────────────────────────────────────────────────────────

@test "resolve_env_file: with env name returns .<name>.env" {
  _load_cli_functions
  result=$(resolve_env_file "knowledge-graph" "prod")
  [[ "$result" == *"/.prod.env" ]]
}

@test "resolve_env_file: staging returns .staging.env" {
  _load_cli_functions
  result=$(resolve_env_file "knowledge-graph" "staging")
  [[ "$result" == *"/.staging.env" ]]
}

@test "resolve_env_file: empty env name returns .env" {
  _load_cli_functions
  result=$(resolve_env_file "knowledge-graph" "")
  [[ "$result" == *"/.env" ]]
  [[ "$result" != *"/.env."* ]]
}

@test "resolve_env_file: jitsi-prod returns .jitsi-prod.env" {
  _load_cli_functions
  result=$(resolve_env_file "jitsi" "jitsi-prod")
  [[ "$result" == *"/.jitsi-prod.env" ]]
}

# ── resolve_env_file: stack-aware (since v0.29.0) ────────────────────────────

@test "resolve_env_file: prefers stack-level env when file exists" {
  _load_cli_functions
  mkdir -p "$CLI_ROOT/stacks/my-stack"
  echo "VPS_HOST=test" > "$CLI_ROOT/stacks/my-stack/.prod.env"
  result=$(resolve_env_file "my-stack" "prod")
  [[ "$result" == *"/stacks/my-stack/.prod.env" ]]
}

@test "resolve_env_file: falls back to project-level when stack-level absent" {
  _load_cli_functions
  local tmp_root; tmp_root=$(mktemp -d)
  CLI_ROOT="$tmp_root"
  mkdir -p "$tmp_root/stacks/my-stack"
  # No .prod.env in stack dir
  result=$(resolve_env_file "my-stack" "prod")
  [[ "$result" == "$tmp_root/.prod.env" ]]
  rm -rf "$tmp_root"
}

@test "resolve_env_file: no env name prefers stack-level .env" {
  _load_cli_functions
  mkdir -p "$CLI_ROOT/stacks/my-stack"
  echo "VPS_HOST=test" > "$CLI_ROOT/stacks/my-stack/.env"
  result=$(resolve_env_file "my-stack" "")
  [[ "$result" == *"/stacks/my-stack/.env" ]]
}

@test "resolve_env_file: no env name falls back to project .env" {
  _load_cli_functions
  local tmp_root; tmp_root=$(mktemp -d)
  CLI_ROOT="$tmp_root"
  mkdir -p "$tmp_root/stacks/my-stack"
  # No .env in stack dir
  result=$(resolve_env_file "my-stack" "")
  [[ "$result" == "$tmp_root/.env" ]]
  rm -rf "$tmp_root"
}

# ── resolve_env_file: secrets-filter .enc.env (strut#178 gap #2) ────────────

@test "resolve_env_file: prefers stack-level .enc.env over stack-level .env" {
  _load_cli_functions
  mkdir -p "$CLI_ROOT/stacks/my-stack"
  rm -f "$CLI_ROOT/stacks/my-stack/.prod.env" "$CLI_ROOT/stacks/my-stack/.prod.enc.env" "$CLI_ROOT/.prod.enc.env"
  echo "VPS_HOST=plain" > "$CLI_ROOT/stacks/my-stack/.prod.env"
  echo "VPS_HOST=enc" > "$CLI_ROOT/stacks/my-stack/.prod.enc.env"
  result=$(resolve_env_file "my-stack" "prod")
  [[ "$result" == *"/stacks/my-stack/.prod.enc.env" ]]
  rm -f "$CLI_ROOT/stacks/my-stack/.prod.env" "$CLI_ROOT/stacks/my-stack/.prod.enc.env"
}

@test "resolve_env_file: stack-level .env still wins over project-level .enc.env" {
  _load_cli_functions
  mkdir -p "$CLI_ROOT/stacks/my-stack"
  rm -f "$CLI_ROOT/stacks/my-stack/.prod.env" "$CLI_ROOT/stacks/my-stack/.prod.enc.env" "$CLI_ROOT/.prod.enc.env"
  echo "VPS_HOST=plain" > "$CLI_ROOT/stacks/my-stack/.prod.env"
  echo "VPS_HOST=enc" > "$CLI_ROOT/.prod.enc.env"
  result=$(resolve_env_file "my-stack" "prod")
  [[ "$result" == *"/stacks/my-stack/.prod.env" ]]
  rm -f "$CLI_ROOT/stacks/my-stack/.prod.env" "$CLI_ROOT/.prod.enc.env"
}

@test "resolve_env_file: falls back to project-level .enc.env when nothing else exists" {
  _load_cli_functions
  local tmp_root; tmp_root=$(mktemp -d)
  CLI_ROOT="$tmp_root"
  mkdir -p "$tmp_root/stacks/my-stack"
  echo "VPS_HOST=enc" > "$tmp_root/.prod.enc.env"
  result=$(resolve_env_file "my-stack" "prod")
  [[ "$result" == "$tmp_root/.prod.enc.env" ]]
  rm -rf "$tmp_root"
}

# ── resolve_compose_cmd ───────────────────────────────────────────────────────

@test "resolve_compose_cmd: builds correct command with stack and env" {
  _load_cli_functions
  # Create a minimal env file
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
EOF
  set -a; source "$TEST_TMP/.prod.env"; set +a

  result=$(resolve_compose_cmd "knowledge-graph" "$TEST_TMP/.prod.env" "")
  [[ "$result" == *"docker compose"* ]]
  [[ "$result" == *"--env-file $TEST_TMP/.prod.env"* ]]
  [[ "$result" == *"--project-name knowledge-graph-prod"* ]]
  [[ "$result" == *"-f $CLI_ROOT/stacks/knowledge-graph/docker-compose.yml"* ]]
}

@test "resolve_compose_cmd: includes profile when specified" {
  _load_cli_functions
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
EOF
  set -a; source "$TEST_TMP/.prod.env"; set +a

  result=$(resolve_compose_cmd "knowledge-graph" "$TEST_TMP/.prod.env" "full")
  [[ "$result" == *"--profile full"* ]]
}

@test "resolve_compose_cmd: no profile when empty" {
  _load_cli_functions
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
EOF
  set -a; source "$TEST_TMP/.prod.env"; set +a

  result=$(resolve_compose_cmd "knowledge-graph" "$TEST_TMP/.prod.env" "")
  [[ "$result" != *"--profile"* ]]
}

@test "resolve_compose_cmd: avoids double-prefix for namespaced env (jitsi-prod)" {
  _load_cli_functions
  cat > "$TEST_TMP/.jitsi-prod.env" <<'EOF'
VPS_HOST=10.0.0.1
EOF
  set -a; source "$TEST_TMP/.jitsi-prod.env"; set +a

  result=$(resolve_compose_cmd "jitsi" "$TEST_TMP/.jitsi-prod.env" "")
  # Should be "jitsi-prod" not "jitsi-jitsi-prod"
  [[ "$result" == *"--project-name jitsi-prod"* ]]
  [[ "$result" != *"jitsi-jitsi-prod"* ]]
}

@test "resolve_compose_cmd: local env gets correct project name" {
  _load_cli_functions
  cat > "$TEST_TMP/.local.env" <<'EOF'
SOME_VAR=test
EOF
  set -a; source "$TEST_TMP/.local.env"; set +a

  result=$(resolve_compose_cmd "knowledge-graph" "$TEST_TMP/.local.env" "")
  [[ "$result" == *"--project-name knowledge-graph-local"* ]]
}

# ── COMPOSE_PROJECT_NAME override (issue #96) ────────────────────────────────

@test "resolve_compose_cmd: respects COMPOSE_PROJECT_NAME from env file" {
  _load_cli_functions
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
COMPOSE_PROJECT_NAME=plane
EOF
  set -a; source "$TEST_TMP/.prod.env"; set +a

  result=$(resolve_compose_cmd "plane" "$TEST_TMP/.prod.env" "")
  # Should use "plane" not "plane-prod"
  [[ "$result" == *"--project-name plane"* ]]
  [[ "$result" != *"--project-name plane-prod"* ]]
}

@test "resolve_compose_cmd: COMPOSE_PROJECT_NAME takes precedence over auto-generated name" {
  _load_cli_functions
  cat > "$TEST_TMP/.local.env" <<'EOF'
COMPOSE_PROJECT_NAME=my-custom-name
EOF
  set -a; source "$TEST_TMP/.local.env"; set +a

  result=$(resolve_compose_cmd "knowledge-graph" "$TEST_TMP/.local.env" "")
  [[ "$result" == *"--project-name my-custom-name"* ]]
  [[ "$result" != *"knowledge-graph-local"* ]]
}

@test "resolve_compose_cmd: auto-generates name when COMPOSE_PROJECT_NAME is not set" {
  _load_cli_functions
  # Ensure COMPOSE_PROJECT_NAME is unset
  unset COMPOSE_PROJECT_NAME
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=10.0.0.1
EOF
  set -a; source "$TEST_TMP/.prod.env"; set +a

  result=$(resolve_compose_cmd "my-app" "$TEST_TMP/.prod.env" "")
  [[ "$result" == *"--project-name my-app-prod"* ]]
}
