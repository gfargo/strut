#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_domain.bats — Smoke tests for cmd_domain handler
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/cmd_domain.sh"

  # Stubs — intercept everything that would touch network/git
  ssh() { echo "ssh $*"; return 0; }
  scp() { echo "scp $*"; return 0; }
  git() { echo "git $*"; return 0; }
  export -f ssh scp git

  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=example.com
VPS_USER=ubuntu
REVERSE_PROXY=caddy
EOF

  export CMD_STACK="test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="test"
  export DRY_RUN=false
}

teardown() {
  common_teardown
}

@test "_usage_domain: prints usage" {
  run _usage_domain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"domain"* ]]
  [[ "$output" == *"--skip-ssl"* ]]
}

@test "cmd_domain: fails without domain arg" {
  run cmd_domain
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_domain: fails without email arg" {
  run cmd_domain example.com
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_domain: dry-run with caddy shows Caddyfile plan" {
  export DRY_RUN=true
  run cmd_domain example.com admin@example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"Caddyfile"* ]] || [[ "$output" == *"caddy"* ]]
}

@test "cmd_domain: dry-run with nginx shows nginx plan" {
  cat > "$TEST_TMP/.nginx.env" <<'EOF'
VPS_HOST=example.com
VPS_USER=ubuntu
REVERSE_PROXY=nginx
EOF
  export CMD_ENV_FILE="$TEST_TMP/.nginx.env"
  export DRY_RUN=true
  run cmd_domain example.com admin@example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"nginx"* ]] || [[ "$output" == *"configure-domain"* ]]
}

@test "cmd_domain: --skip-ssl flag recognized in dry-run" {
  export DRY_RUN=true
  run cmd_domain example.com admin@example.com --skip-ssl
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  # With --skip-ssl, the SSL commit/push steps should NOT appear
  [[ "$output" != *"Commit SSL config"* ]]
}

@test "cmd_domain: dry-run without --skip-ssl includes SSL steps" {
  export DRY_RUN=true
  run cmd_domain example.com admin@example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"Commit SSL config"* ]] || [[ "$output" == *"SSL"* ]]
}
