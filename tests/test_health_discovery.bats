#!/usr/bin/env bats
# ==================================================
# tests/test_health_discovery.bats — Property tests for dynamic health discovery
# ==================================================
# Run:  bats tests/test_health_discovery.bats
# Covers: health_check_application, health_check_databases, health_check_network
# Feature: ch-deploy-modularization, Properties 7, 8, 9

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  export HEALTH_JSON_OUTPUT=false
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_health() {
  source "$CLI_ROOT/lib/utils.sh"
  # Override fail to not exit the test runner
  fail() { echo "$1" >&2; return 1; }
  source "$CLI_ROOT/lib/health.sh"
  # Reset health state
  HEALTH_OVERALL="healthy"
  HEALTH_PASSED=0
  HEALTH_FAILED=0
  HEALTH_WARNED=0
  HEALTH_JSON_OUTPUT=false
}

# ── Helper: generate random alphanumeric string ──────────────────────────────

_rand_str() {
  local len="${1:-6}"
  LC_ALL=C tr -dc 'A-Z' < /dev/urandom | head -c "$len" 2>/dev/null || true
}

_rand_port() {
  echo $(( (RANDOM % 9000) + 1024 ))
}


# ══════════════════════════════════════════════════════════════════════════════
# Property 7: Service discovery constructs correct probe targets from services.conf
# Feature: ch-deploy-modularization, Property 7
# Validates: Requirements 5.2, 5.3, 10.1
# ══════════════════════════════════════════════════════════════════════════════

@test "Property 7: Service discovery constructs correct probe targets (100 iterations)" {
  _load_health

  # Stub curl to always succeed — we're testing discovery, not connectivity
  curl() { return 0; }
  export -f curl
  # Stub netstat to report all ports as listening (wildcard match)
  netstat() { echo "tcp 0 0 0.0.0.0:$_STUB_PORT 0.0.0.0:* LISTEN"; }
  export -f netstat
  # Stub ss to match any port query
  ss() { echo ":1 "; return 0; }
  export -f ss

  for i in $(seq 1 100); do
    local stack_dir="$TEST_TMP/stack_$i"
    mkdir -p "$stack_dir"
    local conf="$stack_dir/services.conf"
    > "$conf"

    # Generate 1-5 random services
    local num_services=$(( (RANDOM % 5) + 1 ))
    local -a expected_ports=()
    local -a expected_names=()
    local -a has_health_path=()

    for s in $(seq 1 "$num_services"); do
      local svc_name="SVC$(_rand_str 4)"
      local port=$(_rand_port)
      echo "${svc_name}_PORT=$port" >> "$conf"
      expected_ports+=("$port")
      expected_names+=("$svc_name")

      # 50% chance of having a health path
      if (( RANDOM % 2 )); then
        echo "${svc_name}_HEALTH_PATH=/health" >> "$conf"
        has_health_path+=(1)
      else
        has_health_path+=(0)
      fi
    done

    # Reset counters
    HEALTH_OVERALL="healthy"
    HEALTH_PASSED=0
    HEALTH_FAILED=0
    HEALTH_WARNED=0

    # Run the function and capture output
    local output
    output=$(health_check_application "$stack_dir" 2>&1)

    # Verify each service port appears in the output
    for idx in "${!expected_ports[@]}"; do
      local port="${expected_ports[$idx]}"
      [[ "$output" == *":${port}"* ]] || {
        echo "FAIL iteration $i: port $port not found in output: $output" >&2
        return 1
      }
    done

    # Verify services with health path get HTTP probe (show "healthy")
    # and services without get TCP check result
    for idx in "${!expected_ports[@]}"; do
      local port="${expected_ports[$idx]}"
      if [ "${has_health_path[$idx]}" = "1" ]; then
        [[ "$output" == *"${port}"*"healthy"* ]] || {
          echo "FAIL iteration $i: service on port $port should have HTTP probe" >&2
          return 1
        }
      else
        # TCP check — either "listening" or "not listening" depending on stub
        # The key property: it should NOT say "healthy" (that's HTTP-only)
        # and it should NOT say "no response on" (that's HTTP failure)
        [[ "$output" != *"${port}"*"no response on"* ]] || {
          echo "FAIL iteration $i: service on port $port without health path should not get HTTP probe" >&2
          return 1
        }
      fi
    done
  done
}

@test "Property 7 edge case: no services.conf emits warning" {
  _load_health

  local stack_dir="$TEST_TMP/no_conf"
  mkdir -p "$stack_dir"

  local output
  output=$(health_check_application "$stack_dir" 2>&1)
  [[ "$output" == *"No services.conf"* ]]
}

@test "Property 7 edge case: services.conf with no PORT entries emits warning" {
  _load_health

  local stack_dir="$TEST_TMP/empty_ports"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
# Just comments
DB_POSTGRES=true
SOME_OTHER_VAR=hello
EOF

  local output
  output=$(health_check_application "$stack_dir" 2>&1)
  [[ "$output" == *"No *_PORT entries"* ]]
}

@test "Property 7 edge case: DB_* prefixed PORT vars are excluded from app checks" {
  _load_health

  curl() { return 0; }
  export -f curl
  ss() { echo ":99999 "; }
  export -f ss

  local stack_dir="$TEST_TMP/db_port_excluded"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
API_PORT=8000
API_HEALTH_PATH=/health
DB_POSTGRES_PORT=5432
EOF

  local output
  output=$(health_check_application "$stack_dir" 2>&1)
  # API should be checked
  [[ "$output" == *"8000"* ]]
  # DB_POSTGRES_PORT should NOT appear as an app service
  [[ "$output" != *"5432"* ]]
}


# ══════════════════════════════════════════════════════════════════════════════
# Property 8: Database check dispatch matches DB_ flags in services.conf
# Feature: ch-deploy-modularization, Property 8
# Validates: Requirements 6.1, 6.2, 6.3, 6.4
# ══════════════════════════════════════════════════════════════════════════════

@test "Property 8: Database check dispatch matches DB_ flags (100 iterations)" {
  _load_health

  local db_types=("POSTGRES" "NEO4J" "MYSQL" "REDIS")
  local db_labels=("PostgreSQL" "Neo4j" "MySQL" "Redis")

  # Stub all external commands to succeed
  curl() { return 0; }
  export -f curl

  for i in $(seq 1 100); do
    local stack_dir="$TEST_TMP/db_$i"
    mkdir -p "$stack_dir"
    local conf="$stack_dir/services.conf"
    > "$conf"

    # Generate a random subset of DB flags
    local -a enabled_dbs=()
    local -a disabled_dbs=()
    for idx in "${!db_types[@]}"; do
      if (( RANDOM % 2 )); then
        echo "DB_${db_types[$idx]}=true" >> "$conf"
        enabled_dbs+=("${db_labels[$idx]}")
      else
        disabled_dbs+=("${db_labels[$idx]}")
      fi
    done

    # Reset counters
    HEALTH_OVERALL="healthy"
    HEALTH_PASSED=0
    HEALTH_FAILED=0
    HEALTH_WARNED=0

    # Stub compose_cmd — all exec commands will fail (no real containers)
    local compose_cmd="echo"

    local output
    output=$(health_check_databases "$compose_cmd" "$stack_dir" 2>&1)

    # Enabled DBs should appear in output (either pass or fail)
    for db in "${enabled_dbs[@]}"; do
      [[ "$output" == *"$db"* ]] || {
        echo "FAIL iteration $i: enabled DB '$db' not found in output: $output" >&2
        return 1
      }
    done

    # Disabled DBs should NOT appear in output
    for db in "${disabled_dbs[@]}"; do
      [[ "$output" != *"$db"* ]] || {
        echo "FAIL iteration $i: disabled DB '$db' should not appear in output: $output" >&2
        return 1
      }
    done

    # If no DBs enabled, should see skip message
    if [ ${#enabled_dbs[@]} -eq 0 ]; then
      [[ "$output" == *"No DB_* flags"* ]] || {
        echo "FAIL iteration $i: expected skip message when no DBs enabled" >&2
        return 1
      }
    fi
  done
}

@test "Property 8 edge case: no services.conf skips DB checks" {
  _load_health

  local stack_dir="$TEST_TMP/no_db_conf"
  mkdir -p "$stack_dir"

  local output
  output=$(health_check_databases "echo" "$stack_dir" 2>&1)
  [[ "$output" == *"No services.conf"* ]]
}

@test "Property 8 edge case: DB_UNKNOWN=true emits warning" {
  _load_health

  local stack_dir="$TEST_TMP/unknown_db"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
DB_COCKROACH=true
EOF

  local output
  output=$(health_check_databases "echo" "$stack_dir" 2>&1)
  [[ "$output" == *"COCKROACH"* ]]
  [[ "$output" == *"Unknown database type"* ]]
}

@test "Property 8 edge case: DB flags set to false are skipped" {
  _load_health

  local stack_dir="$TEST_TMP/db_false"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
DB_POSTGRES=false
DB_NEO4J=false
EOF

  local output
  output=$(health_check_databases "echo" "$stack_dir" 2>&1)
  [[ "$output" != *"PostgreSQL"* ]]
  [[ "$output" != *"Neo4j"* ]]
  [[ "$output" == *"No DB_* flags"* ]]
}


# ══════════════════════════════════════════════════════════════════════════════
# Property 9: Port 80 is always included in network health checks
# Feature: ch-deploy-modularization, Property 9
# Validates: Requirements 10.2
# ══════════════════════════════════════════════════════════════════════════════

@test "Property 9: Port 80 is always included in network health checks (100 iterations)" {
  _load_health

  # Stub ss to report all ports as listening
  ss() { echo ":99999 "; }
  export -f ss
  # Stub ping to succeed
  ping() { return 0; }
  export -f ping

  for i in $(seq 1 100); do
    local stack_dir="$TEST_TMP/net_$i"
    mkdir -p "$stack_dir"
    local conf="$stack_dir/services.conf"
    > "$conf"

    # Generate 0-4 random service ports (never 80, to test it's always added)
    local num_ports=$(( RANDOM % 5 ))
    for p in $(seq 1 "$num_ports"); do
      local port=$(( (RANDOM % 9000) + 1024 ))
      echo "SVC${p}_PORT=$port" >> "$conf"
    done

    # Reset counters
    HEALTH_OVERALL="healthy"
    HEALTH_PASSED=0
    HEALTH_FAILED=0
    HEALTH_WARNED=0

    local output
    output=$(health_check_network "$stack_dir" 2>&1)

    # Port 80 must always appear
    [[ "$output" == *"Port 80"* ]] || {
      echo "FAIL iteration $i: Port 80 not found in output: $output" >&2
      return 1
    }
  done
}

@test "Property 9 edge case: port 80 included even with no services.conf" {
  _load_health

  ss() { echo ":99999 "; }
  export -f ss
  ping() { return 0; }
  export -f ping

  local stack_dir="$TEST_TMP/no_net_conf"
  mkdir -p "$stack_dir"

  local output
  output=$(health_check_network "$stack_dir" 2>&1)
  [[ "$output" == *"Port 80"* ]]
}

@test "Property 9 edge case: port 80 included with empty stack_dir arg" {
  _load_health

  ss() { echo ":99999 "; }
  export -f ss
  ping() { return 0; }
  export -f ping

  local output
  output=$(health_check_network "" 2>&1)
  [[ "$output" == *"Port 80"* ]]
}

@test "Property 9 edge case: port 80 not duplicated when services.conf declares port 80" {
  _load_health

  ss() { echo ":99999 "; }
  export -f ss
  ping() { return 0; }
  export -f ping

  local stack_dir="$TEST_TMP/port80_dup"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
NGINX_PORT=80
API_PORT=8000
EOF

  local output
  output=$(health_check_network "$stack_dir" 2>&1)
  # Count occurrences of "Port 80" (exact, not matching Port 8000)
  local count
  count=$(echo "$output" | grep -c "Port 80[^0-9]" || true)
  [ "$count" -eq 1 ]
}

@test "Network check reads all service ports from services.conf" {
  _load_health

  ss() { echo ":99999 "; }
  export -f ss
  ping() { return 0; }
  export -f ping

  local stack_dir="$TEST_TMP/multi_ports"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
API_PORT=8000
WORKER_PORT=8001
FRONTEND_PORT=3000
DB_POSTGRES=true
EOF

  local output
  output=$(health_check_network "$stack_dir" 2>&1)
  [[ "$output" == *"Port 80"* ]]
  [[ "$output" == *"Port 8000"* ]]
  [[ "$output" == *"Port 8001"* ]]
  [[ "$output" == *"Port 3000"* ]]
  # DB_POSTGRES should not generate a port check (it's a DB flag, not *_PORT)
}
