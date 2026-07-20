#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_first_run.bats — Tests for the first-run command
# ==================================================
# Run:  bats tests/test_cmd_first_run.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/hooks.sh"
  source "$CLI_ROOT/lib/cmd_first_run.sh"

  export LIB="$CLI_ROOT/lib"

  mkdir -p "$TEST_TMP/stacks/test-stack/hooks"
  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
}

teardown() { common_teardown; }

_set_first_run_ctx() {
  local env_file="$1"
  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$env_file"
  export CMD_ENV_NAME="test"
}

_write_hook() {
  cat > "$TEST_TMP/stacks/test-stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "initializing"
EOF
  chmod +x "$TEST_TMP/stacks/test-stack/hooks/first_run.sh"
}

# ── Local dispatch (no VPS_HOST) ──────────────────────────────────────────────

@test "cmd_first_run: bare call is read-only and reports status" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote
  _write_hook
  _set_first_run_ctx ""

  run cmd_first_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"initialized: no"* ]]
  # Bare call must NOT run the hook
  [ ! -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
}

@test "cmd_first_run: --status reports absent marker" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote
  _set_first_run_ctx ""

  run cmd_first_run --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"first_run hook: (none)"* ]]
  [[ "$output" == *"initialized: no"* ]]
}

@test "cmd_first_run: --force runs the hook and writes the marker with a timestamp" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote
  _write_hook
  _set_first_run_ctx ""

  run cmd_first_run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"initializing"* ]]
  [ -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
  grep -q "initialized=" "$TEST_TMP/stacks/test-stack/.strut-initialized"
}

@test "cmd_first_run: --force repairs (re-runs) even when already initialized" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote
  _write_hook
  echo "initialized=2020-01-01T00:00:00Z" > "$TEST_TMP/stacks/test-stack/.strut-initialized"
  _set_first_run_ctx ""

  run cmd_first_run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"initializing"* ]]
  run cat "$TEST_TMP/stacks/test-stack/.strut-initialized"
  [[ "$output" != *"2020-01-01T00:00:00Z"* ]]
}

@test "cmd_first_run: --dry-run makes no changes" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote
  _write_hook
  _set_first_run_ctx ""
  export DRY_RUN=true

  run cmd_first_run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" != *"initializing"* ]]
  [ ! -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
}

@test "cmd_first_run: --force with no hook warns and creates no marker" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote
  _set_first_run_ctx ""

  run cmd_first_run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"No first_run hook found"* ]]
  [ ! -f "$TEST_TMP/stacks/test-stack/.strut-initialized" ]
}

# ── Remote dispatch (VPS-mapped stack) ────────────────────────────────────────

@test "cmd_first_run: dispatches --status remotely for a VPS-mapped stack" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.internal
EOF
  should_dispatch_remote() { return 0; }
  run_remote_strut() { echo "run_remote_strut $*"; }
  export -f should_dispatch_remote run_remote_strut
  _set_first_run_ctx "$TEST_TMP/.test.env"

  run cmd_first_run --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_remote_strut test-stack test first-run --status"* ]]
}

@test "cmd_first_run: dispatches --force remotely for a VPS-mapped stack" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.internal
EOF
  should_dispatch_remote() { return 0; }
  run_remote_strut() { echo "run_remote_strut $*"; }
  export -f should_dispatch_remote run_remote_strut
  _set_first_run_ctx "$TEST_TMP/.test.env"

  run cmd_first_run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_remote_strut test-stack test first-run --force"* ]]
}
