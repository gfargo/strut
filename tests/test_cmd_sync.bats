#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_sync.bats — Tests for strut sync command
# ==================================================
# Run:  bats tests/test_cmd_sync.bats
# Covers: cmd_sync dispatch, env-file mode, topology mode, --all, --dry-run

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  export REAL_CLI_ROOT="$CLI_ROOT"

  source "$CLI_ROOT/lib/topology.sh"
  source "$CLI_ROOT/lib/fleet.sh"
  source "$CLI_ROOT/lib/cmd_sync.sh"

  # Stub ssh so nothing connects out
  ssh() { echo "ssh $*"; return 0; }
  export -f ssh

  # Stub fleet_sync to verify invocations without actual SSH
  fleet_sync() { echo "fleet_sync $*"; return 0; }
  export -f fleet_sync

  # Reset topology state
  _TOPO_HOSTS=()
  _TOPO_STACK_HOST=()
  _TOPO_LOADED=false

  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP"
}

teardown() {
  common_teardown
}

# ── _usage_sync ───────────────────────────────────────────────────────────────

@test "_usage_sync: shows usage header" {
  run _usage_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"strut sync"* ]]
}

@test "_usage_sync: mentions --all flag" {
  run _usage_sync
  [[ "$output" == *"--all"* ]]
}

@test "_usage_sync: mentions --dry-run flag" {
  run _usage_sync
  [[ "$output" == *"--dry-run"* ]]
}

@test "_usage_sync: mentions --force-clean flag" {
  run _usage_sync
  [[ "$output" == *"--force-clean"* ]]
}

# ── cmd_sync: no args ─────────────────────────────────────────────────────────

@test "cmd_sync: no args shows usage and fails" {
  run cmd_sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_sync: --help shows usage and exits 0" {
  run cmd_sync --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "cmd_sync: -h shows usage and exits 0" {
  run cmd_sync -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

# ── cmd_sync: env file mode ───────────────────────────────────────────────────

@test "cmd_sync --env: syncs from env file" {
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=prod.example.com
VPS_USER=ubuntu
VPS_PORT=22
VPS_DEPLOY_DIR=/home/ubuntu/strut
GH_PAT=ghp_test
EOF

  run cmd_sync --env prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet_sync"* ]]
  [[ "$output" == *"prod.example.com"* ]]
}

@test "cmd_sync --env: fails when env file missing" {
  run cmd_sync --env nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "cmd_sync --env: skips env file with no VPS_HOST" {
  cat > "$TEST_TMP/.noop.env" <<'EOF'
# no VPS_HOST here
GH_PAT=token
EOF

  run cmd_sync --env noop
  [ "$status" -ne 0 ]
  [[ "$output" == *"VPS_HOST"* ]] || [[ "$output" == *"not set"* ]] || [[ "$output" == *"skipping"* ]]
}

@test "cmd_sync --env: passes --dry-run to fleet_sync" {
  cat > "$TEST_TMP/.staging.env" <<'EOF'
VPS_HOST=staging.example.com
VPS_USER=deploy
EOF

  run cmd_sync --env staging --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
}

@test "cmd_sync --env: passes --force-clean to fleet_sync" {
  cat > "$TEST_TMP/.dev.env" <<'EOF'
VPS_HOST=dev.example.com
VPS_USER=ubuntu
EOF

  run cmd_sync --env dev --force-clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"--force-clean"* ]]
}

# ── cmd_sync: topology host mode ─────────────────────────────────────────────

@test "cmd_sync <host>: fails for unknown host alias" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa
EOF
  export PROJECT_ROOT="$TEST_TMP"

  # Force topology reload in subshell by unsetting the loaded flag
  topology_load() {
    _TOPO_LOADED=false
    source "$REAL_CLI_ROOT/lib/topology.sh"
    _TOPO_LOADED=false
    command topology_load
  }

  # Simpler approach: directly test the expected behavior
  run bash -c "
    source '$REAL_CLI_ROOT/lib/utils.sh'
    fail() { echo \"\$1\" >&2; return 1; }
    source '$REAL_CLI_ROOT/lib/topology.sh'
    source '$REAL_CLI_ROOT/lib/fleet.sh'
    source '$REAL_CLI_ROOT/lib/cmd_sync.sh'
    fleet_sync() { echo \"fleet_sync \$*\"; return 0; }
    export PROJECT_ROOT='$TEST_TMP'
    cmd_sync nonexistent-host
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown host alias"* ]] || [[ "$output" == *"nonexistent-host"* ]]
}

@test "cmd_sync <host>: resolves topology alias and calls fleet_sync" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 /home/user/.ssh/id_rsa

[stacks]
hub = compass
EOF
  export PROJECT_ROOT="$TEST_TMP"
  _TOPO_LOADED=false

  run cmd_sync compass
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet_sync"* ]]
  [[ "$output" == *"compass.local"* ]]
}

@test "cmd_sync <host>: passes --dry-run when syncing topology host" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
myhost = user@host.example:22 /path/to/key
EOF
  export PROJECT_ROOT="$TEST_TMP"
  _TOPO_LOADED=false

  run cmd_sync myhost --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
}

# ── cmd_sync --all: topology mode ─────────────────────────────────────────────

@test "cmd_sync --all: syncs all topology hosts" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
host-a = user@a.example:22 /path/key
host-b = user@b.example:22 /path/key
EOF
  export PROJECT_ROOT="$TEST_TMP"
  _TOPO_LOADED=false

  run cmd_sync --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet_sync"* ]]
  # Both hosts should be synced
  [[ "$output" == *"a.example"* ]]
  [[ "$output" == *"b.example"* ]]
}

@test "cmd_sync --all: falls back to env files when no topology" {
  # No strut.conf → no topology
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=prod.example.com
VPS_USER=ubuntu
EOF

  run cmd_sync --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet_sync"* ]]
  [[ "$output" == *"prod.example.com"* ]]
}

@test "cmd_sync --all: warns when no topology and no env files" {
  # Empty CLI_ROOT with no env files
  run cmd_sync --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"No topology"* ]] || [[ "$output" == *"no"* ]]
}

@test "cmd_sync --all: passes --dry-run to each host" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
srv1 = user@srv1.example:22
EOF
  export PROJECT_ROOT="$TEST_TMP"
  _TOPO_LOADED=false

  run cmd_sync --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
}

# ── strut sync: accessible as top-level command ───────────────────────────────

@test "strut sync --help: accessible from entrypoint" {
  run bash "$REAL_CLI_ROOT/strut" sync --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}
