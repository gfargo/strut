#!/usr/bin/env bats
# ==================================================
# tests/test_topology.bats — Tests for multi-host topology
# ==================================================
# Run:  bats tests/test_topology.bats

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/topology.sh"
  fail() { echo "FAIL: $1" >&2; return 1; }

  # Reset topology state between tests
  _TOPO_HOSTS=()
  _TOPO_STACK_HOST=()
  _TOPO_LOADED=false
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── topology_load ─────────────────────────────────────────────────────────────

@test "topology_load: parses [hosts] section" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
REGISTRY_TYPE=none

[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa
mac = griffen@mac.local:22 ~/.ssh/id_rsa
pi-ops = pi@pi-ops.local:2222 ~/.ssh/pi_key

[stacks]
plane = compass
hub = compass
immich = mac
EOF

  export PROJECT_ROOT="$TEST_TMP"
  topology_load

  [ "${_TOPO_HOSTS[compass]}" = "gfargo@compass.local:22 ~/.ssh/id_rsa" ]
  [ "${_TOPO_HOSTS[mac]}" = "griffen@mac.local:22 ~/.ssh/id_rsa" ]
  [ "${_TOPO_HOSTS[pi-ops]}" = "pi@pi-ops.local:2222 ~/.ssh/pi_key" ]
}

@test "topology_load: parses [stacks] section" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
hub = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  topology_load

  [ "${_TOPO_STACK_HOST[plane]}" = "compass" ]
  [ "${_TOPO_STACK_HOST[hub]}" = "compass" ]
}

@test "topology_load: skips comments and empty lines" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
# This is a comment
REGISTRY_TYPE=none

[hosts]
# Another comment
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
# Stack mapping
plane = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  topology_load

  [ "${_TOPO_HOSTS[compass]}" = "gfargo@compass.local:22 ~/.ssh/id_rsa" ]
  [ "${_TOPO_STACK_HOST[plane]}" = "compass" ]
}

@test "topology_load: no-op when no strut.conf exists" {
  export PROJECT_ROOT="$TEST_TMP/nonexistent"
  topology_load
  [ ${#_TOPO_HOSTS[@]} -eq 0 ]
}

# ── topology_resolve_host ─────────────────────────────────────────────────────

@test "topology_resolve_host: returns user host port key" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  local user host port key
  read -r user host port key <<< "$(topology_resolve_host "plane")"

  [ "$user" = "gfargo" ]
  [ "$host" = "compass.local" ]
  [ "$port" = "22" ]
  [ "$key" = "~/.ssh/id_rsa" ]
}

@test "topology_resolve_host: handles custom port" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
pi = pi@pi-ops.local:2222 ~/.ssh/pi_key

[stacks]
monitoring = pi
EOF

  export PROJECT_ROOT="$TEST_TMP"
  local user host port key
  read -r user host port key <<< "$(topology_resolve_host "monitoring")"

  [ "$user" = "pi" ]
  [ "$host" = "pi-ops.local" ]
  [ "$port" = "2222" ]
  [ "$key" = "~/.ssh/pi_key" ]
}

@test "topology_resolve_host: defaults port to 22 when not specified" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
simple = user@host.example.com ~/.ssh/key

[stacks]
app = simple
EOF

  export PROJECT_ROOT="$TEST_TMP"
  local user host port key
  read -r user host port key <<< "$(topology_resolve_host "app")"

  [ "$user" = "user" ]
  [ "$host" = "host.example.com" ]
  [ "$port" = "22" ]
  [ "$key" = "~/.ssh/key" ]
}

@test "topology_resolve_host: returns 1 for unmapped stack" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22

[stacks]
plane = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  run topology_resolve_host "unknown-stack"
  [ "$status" -eq 1 ]
}

# ── topology_apply_to_env ─────────────────────────────────────────────────────

@test "topology_apply_to_env: sets VPS_* vars from topology" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  unset VPS_HOST VPS_USER VPS_PORT VPS_SSH_KEY

  topology_apply_to_env "plane"

  [ "$VPS_HOST" = "compass.local" ]
  [ "$VPS_USER" = "gfargo" ]
  [ "$VPS_PORT" = "22" ]
  [ "$VPS_SSH_KEY" = "~/.ssh/id_rsa" ]
}

@test "topology_apply_to_env: env file values take precedence" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  export VPS_HOST="override.example.com"
  export VPS_USER="custom-user"
  unset VPS_PORT VPS_SSH_KEY

  topology_apply_to_env "plane"

  # These should NOT be overridden
  [ "$VPS_HOST" = "override.example.com" ]
  [ "$VPS_USER" = "custom-user" ]
  # These should be filled from topology
  [ "$VPS_PORT" = "22" ]
  [ "$VPS_SSH_KEY" = "~/.ssh/id_rsa" ]
}

@test "topology_apply_to_env: no-op for unmapped stack" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22

[stacks]
plane = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  unset VPS_HOST VPS_USER VPS_PORT VPS_SSH_KEY

  topology_apply_to_env "unknown-stack"

  [ -z "${VPS_HOST:-}" ]
}

# ── topology_list_* ───────────────────────────────────────────────────────────

@test "topology_list_hosts: lists all host aliases" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22
mac = griffen@mac.local:22
pi-ops = pi@pi-ops.local:22
EOF

  export PROJECT_ROOT="$TEST_TMP"
  result=$(topology_list_hosts)
  [[ "$result" == *"compass"* ]]
  [[ "$result" == *"mac"* ]]
  [[ "$result" == *"pi-ops"* ]]
}

@test "topology_list_stacks: lists stacks for a host" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22

[stacks]
plane = compass
hub = compass
immich = mac
EOF

  export PROJECT_ROOT="$TEST_TMP"
  result=$(topology_list_stacks "compass")
  [[ "$result" == *"plane"* ]]
  [[ "$result" == *"hub"* ]]
  [[ "$result" != *"immich"* ]]
}
