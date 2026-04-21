#!/usr/bin/env bats
# ==================================================
# tests/test_hooks.bats — lib/hooks.sh fire_hook dispatcher
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/hooks.sh"

  export STACK_DIR="$TEST_TMP/stack"
  mkdir -p "$STACK_DIR/hooks"
}

teardown() {
  common_teardown
}

@test "fire_hook: no-op when hook file absent" {
  run fire_hook pre_deploy "$STACK_DIR"
  [ "$status" -eq 0 ]
}

@test "fire_hook: runs snake_case hook when present" {
  cat > "$STACK_DIR/hooks/pre_deploy.sh" <<'EOF'
#!/bin/bash
echo "snake case hook ran"
EOF
  run fire_hook pre_deploy "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"snake case hook ran"* ]]
}

@test "fire_hook: falls back to dash-case hook (legacy #18 compat)" {
  cat > "$STACK_DIR/hooks/pre-deploy.sh" <<'EOF'
#!/bin/bash
echo "dash case hook ran"
EOF
  run fire_hook pre_deploy "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dash case hook ran"* ]]
}

@test "fire_hook: prefers snake_case over dash-case when both present" {
  cat > "$STACK_DIR/hooks/pre_deploy.sh" <<'EOF'
#!/bin/bash
echo "snake"
EOF
  cat > "$STACK_DIR/hooks/pre-deploy.sh" <<'EOF'
#!/bin/bash
echo "dash"
EOF
  run fire_hook pre_deploy "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"snake"* ]]
  [[ "$output" != *"dash"* ]]
}

@test "fire_hook: propagates non-zero exit from hook" {
  cat > "$STACK_DIR/hooks/pre_deploy.sh" <<'EOF'
#!/bin/bash
echo "failing hook" >&2
exit 42
EOF
  run fire_hook pre_deploy "$STACK_DIR"
  [ "$status" -eq 42 ]
}

@test "fire_hook: passes env vars through to hook" {
  cat > "$STACK_DIR/hooks/pre_deploy.sh" <<'EOF'
#!/bin/bash
echo "stack=$CMD_STACK env=$CMD_ENV_NAME"
EOF
  export CMD_STACK="my-stack"
  export CMD_ENV_NAME="prod"
  run fire_hook pre_deploy "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack=my-stack env=prod"* ]]
}

@test "fire_hook: works for all event names" {
  for event in pre_deploy post_deploy pre_backup post_backup on_health_fail on_drift_detected; do
    cat > "$STACK_DIR/hooks/${event}.sh" <<EOF
#!/bin/bash
echo "fired $event"
EOF
    run fire_hook "$event" "$STACK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fired $event"* ]]
  done
}

@test "fire_hook_or_warn: returns 0 even when hook fails" {
  cat > "$STACK_DIR/hooks/post_deploy.sh" <<'EOF'
#!/bin/bash
exit 1
EOF
  run fire_hook_or_warn post_deploy "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed (continuing)"* ]]
}

@test "fire_hook_or_warn: succeeds normally when hook passes" {
  cat > "$STACK_DIR/hooks/post_deploy.sh" <<'EOF'
#!/bin/bash
echo "all good"
EOF
  run fire_hook_or_warn post_deploy "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all good"* ]]
}

@test "fire_hook_or_warn: returns 0 when no hook file exists" {
  run fire_hook_or_warn post_deploy "$STACK_DIR"
  [ "$status" -eq 0 ]
}
