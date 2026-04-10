#!/usr/bin/env bats
# ==================================================
# tests/test_required_vars.bats — Property tests for required vars validation
# ==================================================
# Run:  bats tests/test_required_vars.bats
# Covers: required_vars file validation in deploy_stack
# Feature: ch-deploy-modularization, Property 5

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_utils() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
}

# ── Helper: generate random alphanumeric variable name ────────────────────────

_rand_varname() {
  local len="${1:-6}"
  local first
  first=$(LC_ALL=C tr -dc 'A-Z' < /dev/urandom | head -c 1 2>/dev/null || echo "V")
  local rest
  rest=$(LC_ALL=C tr -dc 'A-Z0-9_' < /dev/urandom | head -c "$((len - 1))" 2>/dev/null || echo "AR")
  echo "${first}${rest}"
}

_rand_value() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10 2>/dev/null || echo "val"
}

# ── Helper: validate required vars (mirrors deploy_stack logic) ───────────────

_validate_required_vars() {
  local required_vars_file="$1"
  local env_file="$2"

  set -a; source "$env_file"; set +a

  if [ -f "$required_vars_file" ]; then
    while IFS= read -r var || [ -n "$var" ]; do
      [ -z "$var" ] && continue
      val="$(eval echo "\${${var}:-}")"
      if [ -z "$val" ]; then
        echo "Missing required env var: $var (check $env_file)" >&2
        return 1
      fi
    done < "$required_vars_file"
  fi
  return 0
}

# ── Property 5: Required vars validation passes iff all listed vars are non-empty
# Feature: ch-deploy-modularization, Property 5: Required vars validation passes iff all listed vars are non-empty
# Validates: Requirements 3.2, 3.3

@test "Property 5: validation passes when all required vars are present and non-empty (100 iterations)" {
  _load_utils

  for i in $(seq 1 100); do
    # Generate 1-5 random variable names
    local num_vars=$(( (RANDOM % 5) + 1 ))
    local vars=()
    local env_file="$TEST_TMP/env_$i"
    local req_file="$TEST_TMP/req_$i"
    > "$env_file"
    > "$req_file"

    for j in $(seq 1 "$num_vars"); do
      local vname
      vname="$(_rand_varname)"
      vars+=("$vname")
      echo "$vname" >> "$req_file"
      echo "$vname=$(_rand_value)" >> "$env_file"
    done

    # All vars present → should pass
    run _validate_required_vars "$req_file" "$env_file"
    [ "$status" -eq 0 ]
  done
}

@test "Property 5: validation fails when any required var is missing or empty (100 iterations)" {
  _load_utils

  for i in $(seq 1 100); do
    local num_vars=$(( (RANDOM % 4) + 2 ))
    local vars=()
    local env_file="$TEST_TMP/env_fail_$i"
    local req_file="$TEST_TMP/req_fail_$i"
    > "$env_file"
    > "$req_file"

    # Pick a random index to leave empty/missing
    local missing_idx=$(( RANDOM % num_vars ))

    for j in $(seq 0 $(( num_vars - 1 )) ); do
      local vname
      vname="$(_rand_varname)_${j}"
      vars+=("$vname")
      echo "$vname" >> "$req_file"
      if [ "$j" -ne "$missing_idx" ]; then
        echo "$vname=$(_rand_value)" >> "$env_file"
      fi
      # Missing index: either omit entirely or set empty
      if [ "$j" -eq "$missing_idx" ] && (( RANDOM % 2 )); then
        echo "$vname=" >> "$env_file"
      fi
    done

    # At least one var missing → should fail
    run _validate_required_vars "$req_file" "$env_file"
    [ "$status" -ne 0 ]
    # Error message should contain the missing var name
    [[ "$output" == *"${vars[$missing_idx]}"* ]]
  done
}

# ── Edge case: no required_vars file → skip validation ────────────────────────

@test "validation is skipped when required_vars file does not exist" {
  _load_utils

  local env_file="$TEST_TMP/env_skip"
  echo "SOME_VAR=hello" > "$env_file"

  # Pass a non-existent required_vars path
  run _validate_required_vars "$TEST_TMP/nonexistent_required_vars" "$env_file"
  [ "$status" -eq 0 ]
}

# ── Edge case: empty required_vars file → passes ─────────────────────────────

@test "validation passes when required_vars file is empty" {
  _load_utils

  local env_file="$TEST_TMP/env_empty"
  local req_file="$TEST_TMP/req_empty"
  echo "SOME_VAR=hello" > "$env_file"
  > "$req_file"

  run _validate_required_vars "$req_file" "$env_file"
  [ "$status" -eq 0 ]
}

# ── Error message includes env file path ──────────────────────────────────────

@test "error message includes env file path on failure" {
  _load_utils

  local env_file="$TEST_TMP/my_special.env"
  local req_file="$TEST_TMP/req_path"
  echo "MISSING_VAR" > "$req_file"
  echo "OTHER_VAR=ok" > "$env_file"

  run _validate_required_vars "$req_file" "$env_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$env_file"* ]]
  [[ "$output" == *"MISSING_VAR"* ]]
}
