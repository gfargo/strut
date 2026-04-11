#!/usr/bin/env bats
# ==================================================
# tests/test_validate.bats — Tests for config validation
# ==================================================
# Run:  bats tests/test_validate.bats
# Covers: _validate_strut_conf, _validate_services_conf,
#         _validate_volume_conf, _validate_backup_conf,
#         _validate_required_vars, _is_valid_port, _is_valid_boolean

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/cmd_validate.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-val-"*
  rm -rf "$TEST_TMP"
}

# ── _is_valid_port ────────────────────────────────────────────────────────────

@test "_is_valid_port: accepts port 80" {
  run _is_valid_port "80"
  [ "$status" -eq 0 ]
}

@test "_is_valid_port: accepts port 8080" {
  run _is_valid_port "8080"
  [ "$status" -eq 0 ]
}

@test "_is_valid_port: accepts port 65535" {
  run _is_valid_port "65535"
  [ "$status" -eq 0 ]
}

@test "_is_valid_port: rejects port 0" {
  run _is_valid_port "0"
  [ "$status" -eq 1 ]
}

@test "_is_valid_port: rejects port 70000" {
  run _is_valid_port "70000"
  [ "$status" -eq 1 ]
}

@test "_is_valid_port: rejects non-numeric" {
  run _is_valid_port "abc"
  [ "$status" -eq 1 ]
}

@test "_is_valid_port: rejects empty" {
  run _is_valid_port ""
  [ "$status" -eq 1 ]
}

# ── Property: valid ports accepted, invalid rejected ──────────────────────────

@test "Property: ports 1-65535 accepted, others rejected (100 iterations)" {
  for i in $(seq 1 100); do
    local port=$(( (RANDOM % 70000) ))

    if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
      run _is_valid_port "$port"
      [ "$status" -eq 0 ] || {
        echo "FAILED: port $port should be valid"
        return 1
      }
    else
      run _is_valid_port "$port"
      [ "$status" -eq 1 ] || {
        echo "FAILED: port $port should be invalid"
        return 1
      }
    fi
  done
}

# ── _is_valid_boolean ─────────────────────────────────────────────────────────

@test "_is_valid_boolean: accepts true" {
  run _is_valid_boolean "true"
  [ "$status" -eq 0 ]
}

@test "_is_valid_boolean: accepts false" {
  run _is_valid_boolean "false"
  [ "$status" -eq 0 ]
}

@test "_is_valid_boolean: rejects yes" {
  run _is_valid_boolean "yes"
  [ "$status" -eq 1 ]
}

@test "_is_valid_boolean: rejects 1" {
  run _is_valid_boolean "1"
  [ "$status" -eq 1 ]
}

@test "_is_valid_boolean: rejects empty" {
  run _is_valid_boolean ""
  [ "$status" -eq 1 ]
}

# ── _validate_services_conf ──────────────────────────────────────────────────

@test "validate_services_conf: valid config passes" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
API_PORT=8000
API_HEALTH_PATH=/health
WORKER_PORT=8001
DB_POSTGRES=true
DB_NEO4J=false
EOF

  _VALIDATE_ERRORS=0
  _VALIDATE_WARNINGS=0
  _validate_services_conf "$stack_dir"
  [ "$_VALIDATE_ERRORS" -eq 0 ]
}

@test "validate_services_conf: invalid port detected" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
API_PORT=not_a_number
EOF

  _VALIDATE_ERRORS=0
  run _validate_services_conf "$stack_dir"
  [[ "$output" == *"must be numeric"* ]]
}

@test "validate_services_conf: port out of range detected" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
API_PORT=99999
EOF

  _VALIDATE_ERRORS=0
  run _validate_services_conf "$stack_dir"
  [[ "$output" == *"must be numeric"* ]]
}

@test "validate_services_conf: invalid DB flag detected" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
DB_POSTGRES=yes
EOF

  _VALIDATE_ERRORS=0
  run _validate_services_conf "$stack_dir"
  [[ "$output" == *"must be true or false"* ]]
}

@test "validate_services_conf: health path without leading slash warns" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
API_PORT=8000
API_HEALTH_PATH=health
EOF

  _VALIDATE_ERRORS=0
  _VALIDATE_WARNINGS=0
  _validate_services_conf "$stack_dir"
  [ "$_VALIDATE_WARNINGS" -gt 0 ]
}

@test "validate_services_conf: missing file warns" {
  _VALIDATE_WARNINGS=0
  _validate_services_conf "$TEST_TMP/nonexistent"
  [ "$_VALIDATE_WARNINGS" -gt 0 ]
}

# ── _validate_backup_conf ────────────────────────────────────────────────────

@test "validate_backup_conf: valid config passes" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/backup.conf" <<'EOF'
BACKUP_POSTGRES=true
BACKUP_NEO4J=false
BACKUP_RETAIN_DAYS=30
BACKUP_RETAIN_COUNT=10
BACKUP_SCHEDULE_POSTGRES="0 2 * * *"
EOF

  _VALIDATE_ERRORS=0
  _validate_backup_conf "$stack_dir"
  [ "$_VALIDATE_ERRORS" -eq 0 ]
}

@test "validate_backup_conf: non-numeric retention days detected" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/backup.conf" <<'EOF'
BACKUP_RETAIN_DAYS=thirty
EOF

  run _validate_backup_conf "$stack_dir"
  [[ "$output" == *"must be numeric"* ]]
}

@test "validate_backup_conf: invalid boolean flag detected" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/backup.conf" <<'EOF'
BACKUP_POSTGRES=yes
EOF

  run _validate_backup_conf "$stack_dir"
  [[ "$output" == *"must be true or false"* ]]
}

@test "validate_backup_conf: invalid cron expression detected" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/backup.conf" <<'EOF'
BACKUP_SCHEDULE_POSTGRES="daily"
EOF

  run _validate_backup_conf "$stack_dir"
  [[ "$output" == *"5-field cron"* ]]
}

# ── _validate_required_vars ──────────────────────────────────────────────────

@test "validate_required_vars: all vars present passes" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  echo "MY_VAR" > "$stack_dir/required_vars"
  echo "MY_VAR=hello" > "$TEST_TMP/test.env"

  _VALIDATE_ERRORS=0
  _validate_required_vars "$stack_dir" "$TEST_TMP/test.env"
  [ "$_VALIDATE_ERRORS" -eq 0 ]
}

@test "validate_required_vars: missing var detected" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  echo "MISSING_VAR" > "$stack_dir/required_vars"
  echo "OTHER_VAR=hello" > "$TEST_TMP/test.env"

  _VALIDATE_ERRORS=0
  _validate_required_vars "$stack_dir" "$TEST_TMP/test.env"
  [ "$_VALIDATE_ERRORS" -gt 0 ]
}

# ── cmd_validate integration ─────────────────────────────────────────────────

@test "cmd_validate: returns 0 for valid stack" {
  local stack="test-val-ok-$$"
  local stack_dir="$CLI_ROOT/stacks/$stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
API_PORT=8000
DB_POSTGRES=true
EOF

  export PROJECT_ROOT="$TEST_TMP"
  export CMD_STACK="$stack"
  export CMD_STACK_DIR="$stack_dir"
  export CMD_ENV_FILE="$TEST_TMP/nonexistent.env"
  export CMD_ENV_NAME=""

  run cmd_validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"valid"* ]] || [[ "$output" == *"Valid"* ]]

  rm -rf "$stack_dir"
}

@test "cmd_validate: returns 1 for invalid config" {
  local stack="test-val-bad-$$"
  local stack_dir="$CLI_ROOT/stacks/$stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/services.conf" <<'EOF'
API_PORT=not_a_port
DB_POSTGRES=maybe
EOF

  export PROJECT_ROOT="$TEST_TMP"
  export CMD_STACK="$stack"
  export CMD_STACK_DIR="$stack_dir"
  export CMD_ENV_FILE="$TEST_TMP/nonexistent.env"
  export CMD_ENV_NAME=""

  run cmd_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"error"* ]]

  rm -rf "$stack_dir"
}

# ── Property: random valid configs always pass ────────────────────────────────

@test "Property: valid services.conf always passes validation (100 iterations)" {
  for i in $(seq 1 100); do
    local stack_dir="$TEST_TMP/prop-$i"
    mkdir -p "$stack_dir"

    # Generate random valid config
    local port=$(( (RANDOM % 65534) + 1 ))
    local db_flag="true"
    (( RANDOM % 2 == 0 )) && db_flag="false"

    cat > "$stack_dir/services.conf" <<EOF
APP_PORT=$port
APP_HEALTH_PATH=/health
DB_POSTGRES=$db_flag
EOF

    _VALIDATE_ERRORS=0
    _VALIDATE_WARNINGS=0
    _validate_services_conf "$stack_dir"

    [ "$_VALIDATE_ERRORS" -eq 0 ] || {
      echo "FAILED iteration $i: port=$port db_flag=$db_flag had errors"
      return 1
    }

    rm -rf "$stack_dir"
  done
}

# ── Property: random invalid ports always fail ────────────────────────────────

@test "Property: non-numeric ports always fail validation (100 iterations)" {
  for i in $(seq 1 100); do
    local bad_port
    bad_port=$(head -c 5 /dev/urandom | base64 | tr -d '/+=' | head -c 4)
    bad_port="x${bad_port}"

    local stack_dir="$TEST_TMP/prop-bad-$i"
    mkdir -p "$stack_dir"
    echo "APP_PORT=$bad_port" > "$stack_dir/services.conf"

    run _validate_services_conf "$stack_dir"
    [[ "$output" == *"must be numeric"* ]] || {
      echo "FAILED iteration $i: bad_port='$bad_port' should have failed"
      return 1
    }

    rm -rf "$stack_dir"
  done
}
