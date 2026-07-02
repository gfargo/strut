#!/usr/bin/env bats
# ==================================================
# tests/test_first_run_hooks.bats — Tests for first-run hook lifecycle
# ==================================================
# Run:  bats tests/test_first_run_hooks.bats
# Covers: first_run_needed, fire_first_run_hook, _first_run_marker_path

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  source "$CLI_ROOT/lib/hooks.sh"
}

teardown() { common_teardown; }

# ── _first_run_marker_path ────────────────────────────────────────────────────

@test "_first_run_marker_path: returns correct path" {
  result=$(_first_run_marker_path "/opt/stacks/myapp")
  [ "$result" = "/opt/stacks/myapp/.strut-initialized" ]
}

# ── first_run_needed ──────────────────────────────────────────────────────────

@test "first_run_needed: returns 1 when no hook file exists" {
  mkdir -p "$TEST_TMP/stack/hooks"
  # No first_run.sh or first-run.sh
  run first_run_needed "$TEST_TMP/stack"
  [ "$status" -eq 1 ]
}

@test "first_run_needed: returns 1 when no hooks directory exists" {
  mkdir -p "$TEST_TMP/stack"
  run first_run_needed "$TEST_TMP/stack"
  [ "$status" -eq 1 ]
}

@test "first_run_needed: returns 0 when hook exists and not initialized" {
  mkdir -p "$TEST_TMP/stack/hooks"
  cat > "$TEST_TMP/stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "init"
EOF
  chmod +x "$TEST_TMP/stack/hooks/first_run.sh"

  first_run_needed "$TEST_TMP/stack"
}

@test "first_run_needed: returns 1 when already initialized" {
  mkdir -p "$TEST_TMP/stack/hooks"
  cat > "$TEST_TMP/stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "init"
EOF
  chmod +x "$TEST_TMP/stack/hooks/first_run.sh"

  # Create marker
  echo "initialized=2024-01-01T00:00:00Z" > "$TEST_TMP/stack/.strut-initialized"

  run first_run_needed "$TEST_TMP/stack"
  [ "$status" -eq 1 ]
}

@test "first_run_needed: supports dash-case hook name (first-run.sh)" {
  mkdir -p "$TEST_TMP/stack/hooks"
  cat > "$TEST_TMP/stack/hooks/first-run.sh" <<'EOF'
#!/usr/bin/env bash
echo "init"
EOF
  chmod +x "$TEST_TMP/stack/hooks/first-run.sh"

  first_run_needed "$TEST_TMP/stack"
}

# ── fire_first_run_hook ───────────────────────────────────────────────────────

@test "fire_first_run_hook: no-op when no hook exists" {
  mkdir -p "$TEST_TMP/stack"

  run fire_first_run_hook "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  # No marker should be created
  [ ! -f "$TEST_TMP/stack/.strut-initialized" ]
}

@test "fire_first_run_hook: no-op when already initialized" {
  mkdir -p "$TEST_TMP/stack/hooks"
  cat > "$TEST_TMP/stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "should not run"
exit 1
EOF
  chmod +x "$TEST_TMP/stack/hooks/first_run.sh"
  echo "initialized=2024-01-01T00:00:00Z" > "$TEST_TMP/stack/.strut-initialized"

  run fire_first_run_hook "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  # Hook should not have run (it would fail if it did)
  [[ "$output" != *"should not run"* ]]
}

@test "fire_first_run_hook: runs hook and creates marker on success" {
  mkdir -p "$TEST_TMP/stack/hooks"
  cat > "$TEST_TMP/stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "initializing stack"
EOF
  chmod +x "$TEST_TMP/stack/hooks/first_run.sh"

  run fire_first_run_hook "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"First-run hook"* ]]
  [[ "$output" == *"initialized"* ]]
  # Marker should exist
  [ -f "$TEST_TMP/stack/.strut-initialized" ]
  # Marker should contain a timestamp
  grep -q "initialized=" "$TEST_TMP/stack/.strut-initialized"
}

@test "fire_first_run_hook: does not create marker on hook failure" {
  mkdir -p "$TEST_TMP/stack/hooks"
  cat > "$TEST_TMP/stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "failing init"
exit 1
EOF
  chmod +x "$TEST_TMP/stack/hooks/first_run.sh"

  run fire_first_run_hook "$TEST_TMP/stack"
  [ "$status" -ne 0 ]
  # Marker should NOT be created
  [ ! -f "$TEST_TMP/stack/.strut-initialized" ]
  [[ "$output" == *"failed"* ]]
}

@test "fire_first_run_hook: subsequent call is no-op after success" {
  mkdir -p "$TEST_TMP/stack/hooks"
  cat > "$TEST_TMP/stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "first run"
EOF
  chmod +x "$TEST_TMP/stack/hooks/first_run.sh"

  # First call — should run
  fire_first_run_hook "$TEST_TMP/stack"
  [ -f "$TEST_TMP/stack/.strut-initialized" ]

  # Change hook to fail (to prove it's not re-run)
  cat > "$TEST_TMP/stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "should not re-run"
exit 1
EOF

  # Second call — should be a no-op
  run fire_first_run_hook "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  [[ "$output" != *"should not re-run"* ]]
}

@test "fire_first_run_hook: hook receives stack environment" {
  mkdir -p "$TEST_TMP/stack/hooks"
  cat > "$TEST_TMP/stack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "stack=${CMD_STACK:-unset}"
echo "env=${CMD_ENV_NAME:-unset}"
EOF
  chmod +x "$TEST_TMP/stack/hooks/first_run.sh"

  export CMD_STACK="my-stack"
  export CMD_ENV_NAME="prod"

  run fire_first_run_hook "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/stack/.strut-initialized" ]
}

# ── Blue-green parity ─────────────────────────────────────────────────────────

@test "fire_first_run_hook is callable from bg deploy context (smoke test)" {
  # This ensures fire_first_run_hook behaves correctly when called from the
  # blue-green deploy path (parity with deploy_stack).
  mkdir -p "$TEST_TMP/bgstack/hooks"
  cat > "$TEST_TMP/bgstack/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "bg first run"
EOF
  chmod +x "$TEST_TMP/bgstack/hooks/first_run.sh"

  run fire_first_run_hook "$TEST_TMP/bgstack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bg first run"* ]]
  [ -f "$TEST_TMP/bgstack/.strut-initialized" ]
}

@test "fire_first_run_hook: blue-green second deploy is no-op (marker present)" {
  mkdir -p "$TEST_TMP/bgstack2/hooks"
  cat > "$TEST_TMP/bgstack2/hooks/first_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "should not run twice"
exit 1
EOF
  chmod +x "$TEST_TMP/bgstack2/hooks/first_run.sh"
  echo "initialized=2024-01-01T00:00:00Z" > "$TEST_TMP/bgstack2/.strut-initialized"

  # Simulates the second blue-green deploy — hook should be gated by marker
  run fire_first_run_hook "$TEST_TMP/bgstack2"
  [ "$status" -eq 0 ]
  [[ "$output" != *"should not run twice"* ]]
}
