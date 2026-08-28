#!/usr/bin/env bats
# ==================================================
# tests/test_keys_pull.bats — Tests for lib/keys/pull.sh
# ==================================================
# Run:  bats tests/test_keys_pull.bats
# Covers: keys_pull dispatch (--from vps/containers/env-file/unknown),
#         keys_pull_from_vps (dry-run masking, chmod 600, missing env file,
#         missing VPS_HOST, --force/confirm, --keys filter),
#         keys_pull_from_containers (dry-run masking, chmod 600),
#         keys_pull_from_env_file (copy, chmod 600, dry-run, missing source),
#         keys_pull_help output,
#         security-critical: pulled file always gets mode 600.

setup() {
  export CLI_ROOT
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  STACK="test-keys-pull-$$"
  mkdir -p "$CLI_ROOT/stacks/$STACK"

  source "$CLI_ROOT/lib/utils.sh"
  fail()  { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn()  { echo "$1" >&2; }
  ok()    { echo "$1"; }
  log()   { echo "$1"; }

  # Source the full keys module (includes pull.sh, status.sh, discovery.sh, etc.)
  source "$CLI_ROOT/lib/keys.sh"

  # Stub out network-touching helpers so tests never reach a real host
  validate_vps_connection() { return 0; }
  export -f validate_vps_connection

  # ssh stub: by default succeed and echo the last argument (the remote cmd)
  SSH_CALL_LOG="$TEST_TMP/ssh_calls.log"
  : > "$SSH_CALL_LOG"
  export SSH_CALL_LOG
  ssh() {
    local last_arg="${@: -1}"
    echo "$last_arg" >> "$SSH_CALL_LOG"
    # Only emit env-file content for cat/docker-exec commands; test-f / find
    # / wc commands must not print key values or they will appear in dry-run output.
    case "$last_arg" in
      cat\ *)
        echo "KEY_A=value_a"
        echo "KEY_B=value_b"
        ;;
      "test -f "*)
        : # silent – file-exists check, no output
        ;;
      find\ *)
        echo "/opt/deploy/.prod.env"
        ;;
      wc\ *)
        echo "2"
        ;;
      *"docker exec"*)
        # simulate 'docker exec <container> env'
        echo "KEY_A=value_a"
        echo "KEY_B=value_b"
        ;;
      *)
        : # no output for other commands
        ;;
    esac
    return 0
  }
  export -f ssh

  build_ssh_opts() { echo ""; }
  export -f build_ssh_opts

  resolve_deploy_dir() { echo "/opt/deploy"; }
  export -f resolve_deploy_dir

  confirm() { return 0; }
  export -f confirm

  # .prod.env with a VPS_HOST so most paths proceed
  PROD_ENV="$CLI_ROOT/.prod.env"
  printf 'VPS_HOST=fakehost\nVPS_USER=ubuntu\n' > "$PROD_ENV"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/$STACK"
  rm -f "$CLI_ROOT/.prod.env"
  rm -f "$CLI_ROOT/."*"-pulled.env"
  rm -rf "$TEST_TMP"
}

# ── keys_pull dispatch ────────────────────────────────────────────────────────

@test "keys_pull: --from vps dispatches to keys_pull_from_vps" {
  keys_pull_from_vps()       { echo "CALLED_VPS"; return 0; }
  keys_pull_from_containers() { echo "CALLED_CONTAINERS"; return 0; }
  keys_pull_from_env_file()  { echo "CALLED_ENV"; return 0; }

  run keys_pull "$STACK" --from vps
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED_VPS"* ]]
}

@test "keys_pull: --from containers dispatches to keys_pull_from_containers" {
  keys_pull_from_vps()       { echo "CALLED_VPS"; return 0; }
  keys_pull_from_containers() { echo "CALLED_CONTAINERS"; return 0; }
  keys_pull_from_env_file()  { echo "CALLED_ENV"; return 0; }

  run keys_pull "$STACK" --from containers
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED_CONTAINERS"* ]]
}

@test "keys_pull: --from env-file dispatches to keys_pull_from_env_file" {
  keys_pull_from_vps()       { echo "CALLED_VPS"; return 0; }
  keys_pull_from_containers() { echo "CALLED_CONTAINERS"; return 0; }
  keys_pull_from_env_file()  { echo "CALLED_ENV"; return 0; }

  run keys_pull "$STACK" --from env-file
  [ "$status" -eq 0 ]
  [[ "$output" == *"CALLED_ENV"* ]]
}

@test "keys_pull: unknown --from source fails" {
  run keys_pull "$STACK" --from bogus-source
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown source"* ]]
}

@test "keys_pull: default source is vps (no --from)" {
  keys_pull_from_vps() { echo "VPS_DEFAULT"; return 0; }
  export -f keys_pull_from_vps

  run keys_pull "$STACK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VPS_DEFAULT"* ]]
}

@test "keys_pull: fails for missing stack directory" {
  run keys_pull "nonexistent-stack-$$"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Stack not found"* ]]
}

# ── keys_pull_from_vps: core behavior ────────────────────────────────────────

@test "keys_pull_from_vps: writes env file to default target path" {
  local target="$CLI_ROOT/.${STACK}-pulled.env"
  run keys_pull_from_vps "$STACK" "$target" "false" "false" "" "env"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
}

@test "keys_pull_from_vps: output file gets mode 600" {
  local target="$TEST_TMP/pulled.env"
  run keys_pull_from_vps "$STACK" "$target" "false" "false" "" "env"
  [ "$status" -eq 0 ]
  local perms
  perms=$(stat -c "%a" "$target" 2>/dev/null || stat -f "%OLp" "$target")
  [ "$perms" = "600" ]
}

@test "keys_pull_from_vps: fails when .prod.env is missing" {
  rm -f "$CLI_ROOT/.prod.env"
  local target="$TEST_TMP/pulled.env"
  run keys_pull_from_vps "$STACK" "$target" "false" "false" "" "env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "keys_pull_from_vps: fails when VPS_HOST is not set" {
  printf 'VPS_USER=ubuntu\n' > "$CLI_ROOT/.prod.env"
  local target="$TEST_TMP/pulled.env"
  run keys_pull_from_vps "$STACK" "$target" "false" "false" "" "env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"VPS_HOST"* ]]
}

@test "keys_pull_from_vps: dry-run masks values and writes nothing" {
  local target="$TEST_TMP/pulled-dry.env"
  run keys_pull_from_vps "$STACK" "$target" "true" "false" "" "env"
  [ "$status" -eq 0 ]
  [ ! -f "$target" ]
  [[ "$output" == *"MASKED"* ]]
}

@test "keys_pull_from_vps: dry-run output shows key names" {
  local target="$TEST_TMP/pulled-dry.env"
  # ssh stub returns KEY_A and KEY_B lines
  run keys_pull_from_vps "$STACK" "$target" "true" "false" "" "env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEY_A"* ]] || [[ "$output" == *"KEY_B"* ]]
  [[ "$output" != *"value_a"* ]]
  [[ "$output" != *"value_b"* ]]
}

@test "keys_pull_from_vps: --keys filter passes only matching lines" {
  # ssh stub returns KEY_A and KEY_B; only pull KEY_A
  local target="$TEST_TMP/filtered.env"
  run keys_pull_from_vps "$STACK" "$target" "false" "false" "KEY_A" "env"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  grep -q "KEY_A" "$target"
  # KEY_B should be absent since it doesn't match the filter
  ! grep -q "KEY_B" "$target"
}

@test "keys_pull_from_vps: existing target without --force calls confirm" {
  local target="$TEST_TMP/existing.env"
  echo "OLD=1" > "$target"
  # confirm returns 0 (yes) by default in setup → should proceed
  run keys_pull_from_vps "$STACK" "$target" "false" "false" "" "env"
  [ "$status" -eq 0 ]
}

@test "keys_pull_from_vps: existing target with confirm-no aborts" {
  local target="$TEST_TMP/existing.env"
  echo "OLD=1" > "$target"
  confirm() { return 1; }
  export -f confirm

  run keys_pull_from_vps "$STACK" "$target" "false" "false" "" "env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cancelled"* ]]
}

@test "keys_pull_from_vps: --force skips confirm even when target exists" {
  local target="$TEST_TMP/existing.env"
  echo "OLD=1" > "$target"
  confirm() { echo "confirm should not be called" >&2; return 1; }
  export -f confirm

  run keys_pull_from_vps "$STACK" "$target" "false" "true" "" "env"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
}

@test "keys_pull_from_vps: fails when VPS connection check fails" {
  validate_vps_connection() { return 1; }
  export -f validate_vps_connection

  local target="$TEST_TMP/pulled.env"
  run keys_pull_from_vps "$STACK" "$target" "false" "false" "" "env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot connect"* ]]
}

# ── keys_pull_from_vps: JSON output ──────────────────────────────────────────

@test "keys_pull_from_vps: json format produces a file with .keys object (requires jq)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  local target="$TEST_TMP/pulled.json"
  run keys_pull_from_vps "$STACK" "$target" "false" "false" "" "json"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  # validate it's well-formed JSON with a 'keys' top-level key
  run jq -e '.keys' "$target"
  [ "$status" -eq 0 ]
}

# ── keys_pull_from_containers ────────────────────────────────────────────────

@test "keys_pull_from_containers: dry-run masks values and writes nothing" {
  local target="$TEST_TMP/containers-dry.env"
  run keys_pull_from_containers "$STACK" "mycontainer" "$target" "true" "false" "" "env"
  [ "$status" -eq 0 ]
  [ ! -f "$target" ]
  [[ "$output" == *"MASKED"* ]]
}

@test "keys_pull_from_containers: output file gets mode 600" {
  local target="$TEST_TMP/containers.env"
  run keys_pull_from_containers "$STACK" "mycontainer" "$target" "false" "false" "" "env"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  local perms
  perms=$(stat -c "%a" "$target" 2>/dev/null || stat -f "%OLp" "$target")
  [ "$perms" = "600" ]
}

@test "keys_pull_from_containers: fails when .prod.env is missing" {
  rm -f "$CLI_ROOT/.prod.env"
  local target="$TEST_TMP/containers.env"
  run keys_pull_from_containers "$STACK" "mycontainer" "$target" "false" "false" "" "env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "keys_pull_from_containers: fails when VPS connection check fails" {
  validate_vps_connection() { return 1; }
  export -f validate_vps_connection

  local target="$TEST_TMP/containers.env"
  run keys_pull_from_containers "$STACK" "mycontainer" "$target" "false" "false" "" "env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot connect"* ]]
}

# ── keys_pull_from_env_file ──────────────────────────────────────────────────

@test "keys_pull_from_env_file: copies .prod.env to target with mode 600" {
  local target="$TEST_TMP/env-file-pulled.env"
  run keys_pull_from_env_file "$STACK" "$target" "false" "false"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  local perms
  perms=$(stat -c "%a" "$target" 2>/dev/null || stat -f "%OLp" "$target")
  [ "$perms" = "600" ]
}

@test "keys_pull_from_env_file: copies content faithfully" {
  printf 'SECRET_KEY=abc123\nDB_PASS=hunter2\n' > "$CLI_ROOT/.prod.env"
  local target="$TEST_TMP/env-file-pulled.env"
  run keys_pull_from_env_file "$STACK" "$target" "false" "false"
  [ "$status" -eq 0 ]
  grep -q "SECRET_KEY=abc123" "$target"
  grep -q "DB_PASS=hunter2" "$target"
}

@test "keys_pull_from_env_file: dry-run masks values and writes nothing" {
  printf 'SECRET=val123\n' > "$CLI_ROOT/.prod.env"
  local target="$TEST_TMP/env-dry.env"
  run keys_pull_from_env_file "$STACK" "$target" "true" "false"
  [ "$status" -eq 0 ]
  [ ! -f "$target" ]
  [[ "$output" == *"MASKED"* ]]
}

@test "keys_pull_from_env_file: fails when no env file found" {
  rm -f "$CLI_ROOT/.prod.env"
  local target="$TEST_TMP/env-missing.env"
  run keys_pull_from_env_file "$STACK" "$target" "false" "false"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No env file found"* ]]
}

@test "keys_pull_from_env_file: falls back to stack-specific env file" {
  rm -f "$CLI_ROOT/.prod.env"
  printf 'STACK_SECRET=42\n' > "$CLI_ROOT/.${STACK}-prod.env"
  local target="$TEST_TMP/env-fallback.env"
  run keys_pull_from_env_file "$STACK" "$target" "false" "false"
  [ "$status" -eq 0 ]
  grep -q "STACK_SECRET=42" "$target"
  rm -f "$CLI_ROOT/.${STACK}-prod.env"
}

@test "keys_pull_from_env_file: --force skips confirm on existing target" {
  local target="$TEST_TMP/existing.env"
  echo "OLD=x" > "$target"
  confirm() { echo "confirm should not be called" >&2; return 1; }
  export -f confirm

  run keys_pull_from_env_file "$STACK" "$target" "false" "true"
  [ "$status" -eq 0 ]
}

# ── keys_pull_help ────────────────────────────────────────────────────────────

@test "keys_pull_help: prints usage information" {
  run keys_pull_help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pull Key Values"* ]]
  [[ "$output" == *"--from"* ]]
  [[ "$output" == *"--dry-run"* ]]
}
