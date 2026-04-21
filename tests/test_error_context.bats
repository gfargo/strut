#!/usr/bin/env bats
# ==================================================
# tests/test_error_context.bats — _error_context prefix on warn/fail/error
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  # Source utils.sh directly (NOT via load_utils which overrides fail)
  source "$CLI_ROOT/lib/utils.sh"

  # Override fail so `run` can capture stderr without killing the process
  fail() { echo -e "${RED}✗${NC}  $(_error_prefix)$1" >&2; return 1; }
  export -f fail
}

teardown() {
  common_teardown
  unset _error_context
}

@test "_error_prefix: empty when _error_context unset" {
  unset _error_context
  run _error_prefix
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_error_prefix: formats bracketed prefix when set" {
  export _error_context="my-stack/prod/deploy"
  run _error_prefix
  [ "$status" -eq 0 ]
  [ "$output" = "[my-stack/prod/deploy] " ]
}

@test "fail: no prefix when _error_context unset" {
  unset _error_context
  run fail "bad"
  [ "$status" -ne 0 ]
  [[ "$output" != *"["*"]"* ]]
  [[ "$output" == *"bad"* ]]
}

@test "fail: prepends [ctx] when _error_context set" {
  export _error_context="my-stack/staging/deploy"
  run fail "Env file not found: .staging.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"[my-stack/staging/deploy]"* ]]
  [[ "$output" == *"Env file not found"* ]]
}

@test "warn: prepends [ctx] when _error_context set" {
  export _error_context="my-stack/prod/health"
  run warn "service unhealthy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[my-stack/prod/health]"* ]]
  [[ "$output" == *"service unhealthy"* ]]
}

@test "error: prepends [ctx] when _error_context set" {
  export _error_context="my-stack/prod/backup"
  run error "pg_dump failed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[my-stack/prod/backup]"* ]]
  [[ "$output" == *"pg_dump failed"* ]]
}

@test "log: does not get prefix (informational output stays clean)" {
  export _error_context="my-stack/prod/deploy"
  run log "starting deploy"
  [ "$status" -eq 0 ]
  [[ "$output" != *"my-stack/prod/deploy"* ]]
  [[ "$output" == *"[strut]"* ]]
  [[ "$output" == *"starting deploy"* ]]
}

@test "ok: does not get prefix (success output stays clean)" {
  export _error_context="my-stack/prod/deploy"
  run ok "done"
  [ "$status" -eq 0 ]
  [[ "$output" != *"my-stack/prod/deploy"* ]]
}
