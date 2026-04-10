#!/usr/bin/env bats
# ==================================================
# tests/test_resource_checks.bats — Tests for lib/utils.sh resource & helper functions
# ==================================================
# Run:  bats tests/test_resource_checks.bats
# Covers: check_disk, check_cpu, is_running_on_vps, extract_env_name,
#         validate_subcommand, build_ssh_opts, load_services_conf

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
}

teardown() {
  rm -rf "$TEST_TMP"
  unset VPS_HOST
}

# ── check_disk ────────────────────────────────────────────────────────────────

@test "check_disk: returns 0, 1, or 2 (smoke test)" {
  run check_disk 80 90
  # Should succeed on any machine — just verify it returns a valid code
  [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 2 ]]
}

@test "check_disk: respects custom thresholds (low threshold triggers warn)" {
  # Set warn threshold to 1% — almost any disk will exceed this
  run check_disk 1 99
  [[ "$status" -eq 1 || "$status" -eq 2 ]]
}

# ── check_cpu ─────────────────────────────────────────────────────────────────

@test "check_cpu: returns 0, 1, or 2 (smoke test)" {
  run check_cpu 70 90
  [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 2 ]]
}

# ── is_running_on_vps ────────────────────────────────────────────────────────

@test "is_running_on_vps: returns 1 when VPS_HOST is unset" {
  unset VPS_HOST
  run is_running_on_vps
  [ "$status" -eq 1 ]
}

@test "is_running_on_vps: returns 1 when VPS_HOST is empty" {
  export VPS_HOST=""
  run is_running_on_vps
  [ "$status" -eq 1 ]
}

@test "is_running_on_vps: returns 1 for non-local IP" {
  export VPS_HOST="203.0.113.99"
  run is_running_on_vps
  [ "$status" -eq 1 ]
}

# ── extract_env_name ──────────────────────────────────────────────────────────

@test "extract_env_name: extracts 'prod' from .prod.env" {
  run extract_env_name ".prod.env"
  [ "$output" = "prod" ]
}

@test "extract_env_name: extracts 'staging' from .staging.env" {
  run extract_env_name ".staging.env"
  [ "$output" = "staging" ]
}

@test "extract_env_name: extracts 'local' from .env.local" {
  run extract_env_name ".env.local"
  [ "$output" = "local" ]
}

@test "extract_env_name: returns 'prod' for plain .env" {
  run extract_env_name ".env"
  [ "$output" = "prod" ]
}

@test "extract_env_name: handles path prefix" {
  run extract_env_name "stacks/knowledge-graph/.env.local"
  [ "$output" = "local" ]
}

# ── validate_subcommand ──────────────────────────────────────────────────────

@test "validate_subcommand: returns 0 for valid command" {
  run validate_subcommand "postgres" postgres neo4j mysql sqlite all
  [ "$status" -eq 0 ]
}

@test "validate_subcommand: returns 1 for invalid command" {
  run validate_subcommand "redis" postgres neo4j mysql sqlite all
  [ "$status" -eq 1 ]
}

@test "validate_subcommand: error message lists valid options" {
  run validate_subcommand "bad" foo bar baz
  [ "$status" -eq 1 ]
  [[ "$output" == *"foo"* ]]
  [[ "$output" == *"bar"* ]]
  [[ "$output" == *"baz"* ]]
}

# ── build_ssh_opts ────────────────────────────────────────────────────────────

@test "build_ssh_opts: includes default timeout" {
  run build_ssh_opts
  [[ "$output" == *"ConnectTimeout=10"* ]]
}

@test "build_ssh_opts: includes port when specified" {
  run build_ssh_opts -p 2222
  [[ "$output" == *"-p 2222"* ]]
}

@test "build_ssh_opts: includes SSH key when specified" {
  run build_ssh_opts -k /path/to/key
  [[ "$output" == *"-i /path/to/key"* ]]
}

@test "build_ssh_opts: includes BatchMode when --batch" {
  run build_ssh_opts --batch
  [[ "$output" == *"BatchMode=yes"* ]]
}

@test "build_ssh_opts: includes keepalive when --keepalive" {
  run build_ssh_opts --keepalive
  [[ "$output" == *"ServerAliveInterval=5"* ]]
  [[ "$output" == *"ServerAliveCountMax=2"* ]]
}

@test "build_ssh_opts: combines multiple flags" {
  run build_ssh_opts -p 2222 -k /key --batch --keepalive
  [[ "$output" == *"-p 2222"* ]]
  [[ "$output" == *"-i /key"* ]]
  [[ "$output" == *"BatchMode=yes"* ]]
  [[ "$output" == *"ServerAliveInterval=5"* ]]
}

# ── load_services_conf ────────────────────────────────────────────────────────

@test "load_services_conf: sources services.conf when present" {
  mkdir -p "$TEST_TMP/stack"
  cat > "$TEST_TMP/stack/services.conf" <<'EOF'
CH_API_PORT=9000
CH_CHATBOT_PORT=9501
EOF
  load_services_conf "$TEST_TMP/stack"
  [ "$CH_API_PORT" = "9000" ]
  [ "$CH_CHATBOT_PORT" = "9501" ]
}

@test "load_services_conf: does not fail when services.conf missing" {
  mkdir -p "$TEST_TMP/stack"
  run load_services_conf "$TEST_TMP/stack"
  [ "$status" -eq 0 ]
}

# ── run_cmd (dry-run) ────────────────────────────────────────────────────────

@test "run_cmd: executes command in normal mode" {
  export DRY_RUN="false"
  run run_cmd "test echo" echo "hello"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
}

@test "run_cmd: prints command in dry-run mode" {
  export DRY_RUN="true"
  run run_cmd "test echo" echo "hello"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [[ "$output" == *"echo hello"* ]]
}

@test "run_cmd_eval: executes command string in normal mode" {
  export DRY_RUN="false"
  run run_cmd_eval "test pipe" "echo hello | tr 'h' 'H'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello"* ]]
}

@test "run_cmd_eval: prints command string in dry-run mode" {
  export DRY_RUN="true"
  run run_cmd_eval "test pipe" "echo hello | tr 'h' 'H'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
}
