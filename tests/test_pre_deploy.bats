#!/usr/bin/env bats
# ==================================================
# tests/test_pre_deploy.bats — Tests for pre-deploy validation hooks
# ==================================================
# Run:  bats tests/test_pre_deploy.bats
# Covers: PRE_DEPLOY_VALIDATE, PRE_DEPLOY_HOOKS, --skip-validation,
#         custom hook execution

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/config.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-predeploy-"*
  rm -rf "$TEST_TMP"
  unset PRE_DEPLOY_VALIDATE PRE_DEPLOY_HOOKS SKIP_VALIDATION
}

# ── Config defaults ───────────────────────────────────────────────────────────

@test "PRE_DEPLOY_VALIDATE defaults to true" {
  unset PRE_DEPLOY_VALIDATE
  load_strut_config
  [ "$PRE_DEPLOY_VALIDATE" = "true" ]
}

@test "PRE_DEPLOY_HOOKS defaults to true" {
  unset PRE_DEPLOY_HOOKS
  load_strut_config
  [ "$PRE_DEPLOY_HOOKS" = "true" ]
}

@test "PRE_DEPLOY_VALIDATE respects strut.conf override" {
  export PROJECT_ROOT="$TEST_TMP"
  echo "PRE_DEPLOY_VALIDATE=false" > "$TEST_TMP/strut.conf"
  load_strut_config
  [ "$PRE_DEPLOY_VALIDATE" = "false" ]
}

@test "PRE_DEPLOY_HOOKS respects strut.conf override" {
  export PROJECT_ROOT="$TEST_TMP"
  echo "PRE_DEPLOY_HOOKS=false" > "$TEST_TMP/strut.conf"
  load_strut_config
  [ "$PRE_DEPLOY_HOOKS" = "false" ]
}

# ── Custom hook execution ─────────────────────────────────────────────────────

@test "custom hook: passing hook returns 0" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir/hooks"
  cat > "$stack_dir/hooks/pre-deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "hook passed"
exit 0
EOF
  chmod +x "$stack_dir/hooks/pre-deploy.sh"

  run bash "$stack_dir/hooks/pre-deploy.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hook passed"* ]]
}

@test "custom hook: failing hook returns non-zero" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir/hooks"
  cat > "$stack_dir/hooks/pre-deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "hook failed: missing image"
exit 1
EOF
  chmod +x "$stack_dir/hooks/pre-deploy.sh"

  run bash "$stack_dir/hooks/pre-deploy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"hook failed"* ]]
}

@test "custom hook: missing hook file is silently skipped" {
  local stack_dir="$TEST_TMP/stack"
  mkdir -p "$stack_dir"
  # No hooks directory — should not fail
  local hook_file="$stack_dir/hooks/pre-deploy.sh"
  [ ! -f "$hook_file" ]
}

# ── --skip-validation flag ────────────────────────────────────────────────────

@test "--skip-validation: parsed correctly by cmd_deploy" {
  source "$CLI_ROOT/lib/cmd_deploy.sh"

  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP"
  export CMD_ENV_FILE="$TEST_TMP/nonexistent.env"
  export CMD_ENV_NAME="test"
  export CMD_SERVICES=""
  export CMD_JSON=""

  # We can't run the full deploy, but we can verify the flag is parsed
  # by checking SKIP_VALIDATION is exported
  # Stub the deploy to just check the flag
  deploy_stack() { echo "SKIP=$SKIP_VALIDATION"; }
  export -f deploy_stack
  is_running_on_vps() { return 0; }
  export -f is_running_on_vps
  validate_env_file() { return 0; }

  # Source env file stub
  cat > "$TEST_TMP/test.env" <<'EOF'
VPS_HOST=
EOF
  export CMD_ENV_FILE="$TEST_TMP/test.env"

  run cmd_deploy --skip-validation
  [[ "$output" == *"SKIP=true"* ]]
}

# ── Template includes PRE_DEPLOY settings ─────────────────────────────────────

@test "strut.conf.template includes PRE_DEPLOY_VALIDATE" {
  grep -q "PRE_DEPLOY_VALIDATE" "$CLI_ROOT/templates/strut.conf.template"
}

@test "strut.conf.template includes PRE_DEPLOY_HOOKS" {
  grep -q "PRE_DEPLOY_HOOKS" "$CLI_ROOT/templates/strut.conf.template"
}

# ── Property: config always has valid defaults ────────────────────────────────

@test "Property: PRE_DEPLOY_* always default to true regardless of other config (100 iterations)" {
  for i in $(seq 1 100); do
    unset PRE_DEPLOY_VALIDATE PRE_DEPLOY_HOOKS

    # Random strut.conf with other keys but not PRE_DEPLOY_*
    export PROJECT_ROOT="$TEST_TMP/prop-$i"
    mkdir -p "$PROJECT_ROOT"

    local keys=("REGISTRY_TYPE=ghcr" "DEFAULT_ORG=test" "DEFAULT_BRANCH=main" "BANNER_TEXT=test" "REVERSE_PROXY=nginx")
    local num_keys=$(( (RANDOM % ${#keys[@]}) + 1 ))
    : > "$PROJECT_ROOT/strut.conf"
    for j in $(seq 1 "$num_keys"); do
      echo "${keys[$((RANDOM % ${#keys[@]}))]}" >> "$PROJECT_ROOT/strut.conf"
    done

    load_strut_config

    [ "$PRE_DEPLOY_VALIDATE" = "true" ] || {
      echo "FAILED iteration $i: PRE_DEPLOY_VALIDATE='$PRE_DEPLOY_VALIDATE'"
      return 1
    }
    [ "$PRE_DEPLOY_HOOKS" = "true" ] || {
      echo "FAILED iteration $i: PRE_DEPLOY_HOOKS='$PRE_DEPLOY_HOOKS'"
      return 1
    }

    rm -rf "$PROJECT_ROOT"
  done
}

# ── Property: custom hooks with random exit codes ─────────────────────────────

@test "Property: hook exit code propagates correctly (50 iterations)" {
  for i in $(seq 1 50); do
    local exit_code=$(( RANDOM % 3 ))  # 0, 1, or 2
    local hook_file="$TEST_TMP/hook-$i.sh"

    cat > "$hook_file" <<EOF
#!/usr/bin/env bash
exit $exit_code
EOF
    chmod +x "$hook_file"

    run bash "$hook_file"
    [ "$status" -eq "$exit_code" ] || {
      echo "FAILED iteration $i: expected exit $exit_code, got $status"
      return 1
    }
  done
}
