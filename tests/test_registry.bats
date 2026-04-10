#!/usr/bin/env bats
# ==================================================
# tests/test_registry.bats — Property tests for lib/registry.sh
# ==================================================
# Run:  bats tests/test_registry.bats
# Covers: registry_login dispatch
# Feature: ch-deploy-modularization, Properties 3, 4

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  # Create mock docker/aws commands that log what they receive
  mkdir -p "$TEST_TMP/bin"

  cat > "$TEST_TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
# Log the full command for verification
echo "DOCKER_CMD: docker $*" >> "$MOCK_LOG"
# Read stdin if present (for --password-stdin)
if [[ "$*" == *"--password-stdin"* ]]; then
  local stdin_data
  stdin_data=$(cat)
  echo "DOCKER_STDIN: $stdin_data" >> "$MOCK_LOG"
fi
exit 0
MOCK
  chmod +x "$TEST_TMP/bin/docker"

  cat > "$TEST_TMP/bin/aws" <<'MOCK'
#!/usr/bin/env bash
echo "AWS_CMD: aws $*" >> "$MOCK_LOG"
echo "mock-ecr-token"
exit 0
MOCK
  chmod +x "$TEST_TMP/bin/aws"

  export MOCK_LOG="$TEST_TMP/mock.log"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_registry() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  source "$CLI_ROOT/lib/registry.sh"
  # Prepend mock bin to PATH
  export PATH="$TEST_TMP/bin:$PATH"
}

# ── Helper: generate random string ───────────────────────────────────────────

_rand_str() {
  local len="${1:-8}"
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$len" 2>/dev/null || true
}

# ── Property 3: Registry dispatch routes to the correct auth command ─────────
# Feature: ch-deploy-modularization, Property 3: Registry dispatch routes to the correct auth command
# Validates: Requirements 2.1, 2.2, 2.3, 2.4

@test "Property 3: Registry dispatch routes to the correct auth command (100 iterations)" {
  _load_registry

  local types=("ghcr" "dockerhub" "ecr" "none")

  for i in $(seq 1 100); do
    # Pick a random valid registry type
    local idx=$(( RANDOM % ${#types[@]} ))
    local rtype="${types[$idx]}"

    # Clear mock log
    > "$MOCK_LOG"

    # Set up required env vars for each type
    export GH_PAT="ghp_test_$(_rand_str 6)"
    export DOCKER_USER="user_$(_rand_str 4)"
    export DOCKER_PASS="pass_$(_rand_str 6)"
    export REGISTRY_HOST="123456789.dkr.ecr.us-east-1.amazonaws.com"
    export REGISTRY_TYPE="$rtype"

    # Run registry_login
    registry_login

    case "$rtype" in
      ghcr)
        # Should call docker login ghcr.io
        grep -q "DOCKER_CMD:.*login ghcr.io" "$MOCK_LOG"
        ;;
      dockerhub)
        # Should call docker login with DOCKER_USER
        grep -q "DOCKER_CMD:.*login.*-u $DOCKER_USER" "$MOCK_LOG"
        ;;
      ecr)
        # Should call aws ecr get-login-password
        grep -q "AWS_CMD:.*ecr get-login-password" "$MOCK_LOG"
        # Should call docker login with REGISTRY_HOST
        grep -q "DOCKER_CMD:.*login.*$REGISTRY_HOST" "$MOCK_LOG"
        ;;
      none)
        # Should NOT call docker login at all
        ! grep -q "DOCKER_CMD:" "$MOCK_LOG"
        ;;
    esac
  done
}

# ── Property 3 unit tests: individual type verification ──────────────────────

@test "registry_login: ghcr authenticates with GH_PAT against ghcr.io" {
  _load_registry
  > "$MOCK_LOG"
  export REGISTRY_TYPE="ghcr"
  export GH_PAT="ghp_test_token"

  registry_login

  grep -q "DOCKER_CMD:.*login ghcr.io" "$MOCK_LOG"
}

@test "registry_login: dockerhub authenticates with DOCKER_USER/DOCKER_PASS" {
  _load_registry
  > "$MOCK_LOG"
  export REGISTRY_TYPE="dockerhub"
  export DOCKER_USER="myuser"
  export DOCKER_PASS="mypass"

  registry_login

  grep -q "DOCKER_CMD:.*login.*-u myuser" "$MOCK_LOG"
}

@test "registry_login: ecr authenticates with aws ecr against REGISTRY_HOST" {
  _load_registry
  > "$MOCK_LOG"
  export REGISTRY_TYPE="ecr"
  export REGISTRY_HOST="123456789.dkr.ecr.us-east-1.amazonaws.com"

  registry_login

  grep -q "AWS_CMD:.*ecr get-login-password" "$MOCK_LOG"
  grep -q "DOCKER_CMD:.*login.*123456789.dkr.ecr.us-east-1.amazonaws.com" "$MOCK_LOG"
}

@test "registry_login: none skips authentication" {
  _load_registry
  > "$MOCK_LOG"
  export REGISTRY_TYPE="none"

  run registry_login

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping authentication"* ]]
  ! grep -q "DOCKER_CMD:" "$MOCK_LOG"
}

# ── Property 4: Invalid registry type is rejected with supported types listed ─
# Feature: ch-deploy-modularization, Property 4: Invalid registry type is rejected with supported types listed
# Validates: Requirements 2.5

@test "Property 4: Invalid registry type is rejected with supported types listed (100 iterations)" {
  _load_registry

  local valid_types=("ghcr" "dockerhub" "ecr" "none")

  for i in $(seq 1 100); do
    # Generate a random string that is NOT a valid type
    local invalid_type="invalid_$(_rand_str 6)"

    # Make sure it's not accidentally valid
    local is_valid=false
    for vt in "${valid_types[@]}"; do
      [ "$invalid_type" = "$vt" ] && is_valid=true
    done
    $is_valid && continue

    export REGISTRY_TYPE="$invalid_type"

    run registry_login

    # Should fail
    [ "$status" -ne 0 ]

    # Error message should list all four supported types
    [[ "$output" == *"ghcr"* ]]
    [[ "$output" == *"dockerhub"* ]]
    [[ "$output" == *"ecr"* ]]
    [[ "$output" == *"none"* ]]
  done
}

# ── Property 4 unit test: specific invalid type ──────────────────────────────

@test "registry_login: unknown type 'azure' fails with supported types" {
  _load_registry
  export REGISTRY_TYPE="azure"

  run registry_login

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported registry type"* ]]
  [[ "$output" == *"ghcr"* ]]
  [[ "$output" == *"dockerhub"* ]]
  [[ "$output" == *"ecr"* ]]
  [[ "$output" == *"none"* ]]
}

# ── Requirement 2.6: Auth failure warns and continues ─────────────────────────

@test "registry_login: auth failure warns and continues (ghcr)" {
  _load_registry

  # Create a docker mock that fails login
  cat > "$TEST_TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"login"* ]]; then
  exit 1
fi
exit 0
MOCK
  chmod +x "$TEST_TMP/bin/docker"

  export REGISTRY_TYPE="ghcr"
  export GH_PAT="ghp_test_token"

  # Should not fail (warn + continue)
  run registry_login
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed"* ]] || [[ "$output" == *"warn"* ]] || [[ "$output" == *"locally"* ]]
}
