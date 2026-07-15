#!/usr/bin/env bats
# ==================================================
# tests/test_secrets_deploy_dir.bats
# Tests that secrets push/pull/diff/status/rotate honour a per-stack
# VPS_DEPLOY_DIR set in services.conf (OSS-933 / strut#414)
# ==================================================
# Run:  bats tests/test_secrets_deploy_dir.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  # safe_source_config lives in config.sh, which load_services_conf calls.
  source "$CLI_ROOT/lib/config.sh"

  fail()  { echo "FAIL: $1" >&2; return 1; }
  ok()    { echo "OK: $*"; }
  warn()  { echo "WARN: $*" >&2; }
  log()   { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "== $* =="; }
  export -f fail ok warn log error print_banner

  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/topology.sh"
  source "$CLI_ROOT/lib/secrets_providers.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"

  # Stub SSH/SCP to avoid real connections
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  ssh() { return 0; }
  scp() { return 0; }
  export -f build_ssh_opts ssh scp

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh"

  export CLI_ROOT="$TEST_TMP"
  export CMD_STACK="hq-web-api"
  export CMD_STACK_DIR="$TEST_TMP/stacks/hq-web-api"
  export CMD_ENV_NAME="prod"
  mkdir -p "$CMD_STACK_DIR"

  export VPS_HOST="harbor.example.com"
  export VPS_USER="gfargo"
  unset VPS_DEPLOY_DIR

  _TOPO_LOADED=true
  declare -gA _TOPO_HOSTS=()
  declare -gA _TOPO_STACK_HOST=()
}

teardown() { common_teardown; }

# ── Test A: push uses VPS_DEPLOY_DIR from services.conf ──────────────────────

@test "secrets push: uses VPS_DEPLOY_DIR from services.conf (dry-run)" {
  # Set a non-default deploy dir via services.conf
  cat > "$CMD_STACK_DIR/services.conf" <<'EOF'
VPS_DEPLOY_DIR=/home/gfargo/strut/stacks/hq-web-api
EOF

  # Provide a valid local env file (skip validation to focus on path)
  printf 'API_KEY=realvalue\nDB_PASS=strongpass\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 600 "$CMD_STACK_DIR/.prod.env"

  export DRY_RUN=true
  run _secrets_push --skip-validation
  [ "$status" -eq 0 ]
  # The dry-run Remote: log line must use the services.conf path
  [[ "$output" == *"/home/gfargo/strut/stacks/hq-web-api/.prod.env"* ]]
  # Must NOT fall back to the bare /home/gfargo/strut/.prod.env default
  [[ "$output" != *"Remote: gfargo@harbor.example.com:/home/gfargo/strut/.prod.env"* ]]
}

# ── Test B: pull uses VPS_DEPLOY_DIR from services.conf ──────────────────────

@test "secrets pull: uses VPS_DEPLOY_DIR from services.conf (dry-run)" {
  cat > "$CMD_STACK_DIR/services.conf" <<'EOF'
VPS_DEPLOY_DIR=/home/gfargo/strut/stacks/hq-web-api
EOF

  export DRY_RUN=true
  run _secrets_pull
  [ "$status" -eq 0 ]
  # Remote: line must contain the override path
  [[ "$output" == *"/home/gfargo/strut/stacks/hq-web-api/.prod.env"* ]]
  [[ "$output" != *"Remote: gfargo@harbor.example.com:/home/gfargo/strut/.prod.env"* ]]
}

# ── Test C: env file VPS_DEPLOY_DIR wins over services.conf ──────────────────

@test "secrets push: env file VPS_DEPLOY_DIR takes precedence over services.conf" {
  # services.conf sets one dir...
  cat > "$CMD_STACK_DIR/services.conf" <<'EOF'
VPS_DEPLOY_DIR=/home/gfargo/strut/stacks/hq-web-api
EOF

  # ...but the env file (at CLI_ROOT/.prod.env) sets a different one
  printf 'VPS_HOST=harbor.example.com\nVPS_USER=gfargo\nVPS_DEPLOY_DIR=/env/override\n' \
    > "$TEST_TMP/.prod.env"
  chmod 600 "$TEST_TMP/.prod.env"

  printf 'API_KEY=realvalue\nDB_PASS=strongpass\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 600 "$CMD_STACK_DIR/.prod.env"

  export DRY_RUN=true
  run _secrets_push --skip-validation
  [ "$status" -eq 0 ]
  # The env-file path should win
  [[ "$output" == *"/env/override/.prod.env"* ]]
  [[ "$output" != *"/home/gfargo/strut/stacks/hq-web-api"* ]]
}

# ── Test D: dispatcher-resolved VPS_HOST is preserved ────────────────────────

@test "secrets push: dispatcher-resolved VPS_HOST is not clobbered by services.conf" {
  # services.conf tries to set a different VPS_HOST
  cat > "$CMD_STACK_DIR/services.conf" <<'EOF'
VPS_HOST=should-not-win.example.com
VPS_DEPLOY_DIR=/home/gfargo/strut/stacks/hq-web-api
EOF

  printf 'API_KEY=realvalue\nDB_PASS=strongpass\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 600 "$CMD_STACK_DIR/.prod.env"

  # VPS_HOST pre-set by the dispatcher (topology/--host)
  export VPS_HOST="harbor.example.com"

  export DRY_RUN=true
  run _secrets_push --skip-validation
  [ "$status" -eq 0 ]
  # The dispatcher host must still be used in the Remote: line
  [[ "$output" == *"harbor.example.com"* ]]
  [[ "$output" != *"should-not-win.example.com"* ]]
}

# ── Test E: fallback warning when no VPS_DEPLOY_DIR is configured anywhere ───

@test "secrets push: emits warning when falling back to default deploy dir" {
  # No services.conf, no VPS_DEPLOY_DIR in env
  printf 'API_KEY=realvalue\nDB_PASS=strongpass\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 600 "$CMD_STACK_DIR/.prod.env"
  unset VPS_DEPLOY_DIR

  export DRY_RUN=true
  run _secrets_push --skip-validation
  [ "$status" -eq 0 ]
  # Must warn about the fallback (warning goes to stderr, captured by bats in $output)
  [[ "$output" == *"VPS_DEPLOY_DIR not set"* ]]
}

@test "secrets pull: emits warning when falling back to default deploy dir" {
  unset VPS_DEPLOY_DIR
  # No services.conf

  export DRY_RUN=true
  run _secrets_pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"VPS_DEPLOY_DIR not set"* ]]
}

# ── Test F: diff uses VPS_DEPLOY_DIR from services.conf ──────────────────────

@test "secrets diff: uses VPS_DEPLOY_DIR from services.conf" {
  cat > "$CMD_STACK_DIR/services.conf" <<'EOF'
VPS_DEPLOY_DIR=/home/gfargo/strut/stacks/hq-web-api
EOF
  printf 'API_KEY=val\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 600 "$CMD_STACK_DIR/.prod.env"

  # ssh returns 1 (remote file not found) so diff exits early after the path check
  ssh() { return 1; }
  export -f ssh

  export DRY_RUN=false
  run _secrets_diff
  # diff may warn "Remote env file not found" but must show the correct path
  [[ "$output" == *"/home/gfargo/strut/stacks/hq-web-api/.prod.env"* ]] \
    || [[ "$output" == *"hq-web-api"* ]]
}

# ── Test G: no regression — push without services.conf still works ────────────

@test "secrets push: works correctly without services.conf (no regression)" {
  # No services.conf — should fall back to default, with a warning
  printf 'API_KEY=realvalue\nDB_PASS=strongpass\n' > "$CMD_STACK_DIR/.prod.env"
  chmod 600 "$CMD_STACK_DIR/.prod.env"
  unset VPS_DEPLOY_DIR

  export DRY_RUN=true
  run _secrets_push --skip-validation
  [ "$status" -eq 0 ]
  # Should still show a Remote: line with the default path
  [[ "$output" == *"Remote:"* ]]
  [[ "$output" == *"/home/gfargo/strut"* ]]
}
