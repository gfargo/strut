#!/usr/bin/env bats
# ==================================================
# tests/test_local_helpers.bats — Tests for lib/local.sh pure functions
# ==================================================
# Run:  bats tests/test_local_helpers.bats
# Covers: local_validate_env, local_check_ports, local_show_endpoints

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override fail/warn/log/ok/error to not exit
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  source "$CLI_ROOT/lib/local.sh"
}

teardown() { common_teardown; }

# ── local_validate_env ────────────────────────────────────────────────────────

@test "local_validate_env: passes when all template vars are in .env.local" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/.env.template" <<'EOF'
VPS_HOST=your.host.com
VPS_USER=ubuntu
APP_PORT=3000
EOF

  cat > "$TEST_TMP/stacks/$stack/.env.local" <<'EOF'
VPS_HOST=localhost
VPS_USER=dev
APP_PORT=3000
EOF

  run local_validate_env "$stack"
  [ "$status" -eq 0 ]
}

@test "local_validate_env: passes when no .env.template exists" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  # No .env.template — should skip validation
  run local_validate_env "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No .env.template found"* ]]
}

@test "local_validate_env: fails when .env.local is missing" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/.env.template" <<'EOF'
VPS_HOST=your.host.com
EOF

  # No .env.local
  run local_validate_env "$stack"
  [ "$status" -ne 0 ]
  [[ "$output" == *".env.local not found"* ]]
}

@test "local_validate_env: warns about missing placeholder vars" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/.env.template" <<'EOF'
VPS_HOST=your.host.com
GH_PAT=ghp_xxx
SECRET_KEY=changeme
NORMAL_VAR=actual_default
EOF

  cat > "$TEST_TMP/stacks/$stack/.env.local" <<'EOF'
VPS_HOST=localhost
NORMAL_VAR=something
EOF

  # Should warn about GH_PAT and SECRET_KEY (placeholder values)
  # but still return 0 (warnings, not failures)
  run local_validate_env "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GH_PAT"* ]]
  [[ "$output" == *"SECRET_KEY"* ]]
}

@test "local_validate_env: skips vars with real default values" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/.env.template" <<'EOF'
APP_PORT=3000
LOG_LEVEL=info
DEBUG=false
EOF

  cat > "$TEST_TMP/stacks/$stack/.env.local" <<'EOF'
APP_PORT=8080
EOF

  # LOG_LEVEL and DEBUG have real defaults, should not warn
  run local_validate_env "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" != *"LOG_LEVEL"* ]]
  [[ "$output" != *"DEBUG"* ]]
}

# ── local_check_ports ─────────────────────────────────────────────────────────

@test "local_check_ports: passes when no compose file exists" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  # No docker-compose files at all
  run local_check_ports "$stack"
  [ "$status" -eq 0 ]
}

@test "local_check_ports: passes when ports are free" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  # Use a port that's almost certainly not in use
  cat > "$TEST_TMP/stacks/$stack/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx
    ports:
      - "59999:80"
EOF

  run local_check_ports "$stack"
  [ "$status" -eq 0 ]
}

@test "local_check_ports: extracts quoted port mappings" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx
    ports:
      - "59998:80"
      - "59997:443"
EOF

  run local_check_ports "$stack"
  [ "$status" -eq 0 ]
}

@test "local_check_ports: extracts unquoted port mappings" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx
    ports:
      - 59996:80
      - 59995:443
EOF

  run local_check_ports "$stack"
  [ "$status" -eq 0 ]
}

@test "local_check_ports: prefers docker-compose.local.yml over docker-compose.yml" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  # docker-compose.yml has a port that might conflict
  cat > "$TEST_TMP/stacks/$stack/docker-compose.yml" <<'EOF'
services:
  web:
    ports:
      - "80:80"
EOF

  # docker-compose.local.yml uses a safe port
  cat > "$TEST_TMP/stacks/$stack/docker-compose.local.yml" <<'EOF'
services:
  web:
    ports:
      - "59994:80"
EOF

  run local_check_ports "$stack"
  [ "$status" -eq 0 ]
}

# ── local_show_endpoints ──────────────────────────────────────────────────────

@test "local_show_endpoints: shows localhost URLs for mapped ports" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx
    ports:
      - "8080:80"
  api:
    image: node
    ports:
      - "3000:3000"
EOF

  run local_show_endpoints "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://localhost:8080"* ]]
  [[ "$output" == *"http://localhost:3000"* ]]
}

@test "local_show_endpoints: no output when no compose file" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  run local_show_endpoints "$stack"
  [ "$status" -eq 0 ]
}

@test "local_show_endpoints: prefers docker-compose.local.yml" {
  local stack="test-stack"
  mkdir -p "$TEST_TMP/stacks/$stack"
  export CLI_ROOT="$TEST_TMP"

  cat > "$TEST_TMP/stacks/$stack/docker-compose.yml" <<'EOF'
services:
  web:
    ports:
      - "80:80"
EOF

  cat > "$TEST_TMP/stacks/$stack/docker-compose.local.yml" <<'EOF'
services:
  web:
    ports:
      - "9090:80"
EOF

  run local_show_endpoints "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://localhost:9090"* ]]
  [[ "$output" != *"http://localhost:80"* ]]
}
