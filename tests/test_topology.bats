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

# ── topology_resolve_arch (OSS-262) ───────────────────────────────────────────

@test "topology_resolve_arch: echoes the declared arch= for a mapped stack" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
pi-ops = pi@pi-ops.local:2222 ~/.ssh/pi_key arch=arm64

[stacks]
edge-app = pi-ops
EOF

  export PROJECT_ROOT="$TEST_TMP"
  [ "$(topology_resolve_arch "edge-app")" = "arm64" ]
}

@test "topology_resolve_arch: empty when no arch= declared" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22

[stacks]
plane = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  [ "$(topology_resolve_arch "plane")" = "" ]
}

@test "topology_resolve_arch: returns 1 for unmapped stack" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22

[stacks]
plane = compass
EOF

  export PROJECT_ROOT="$TEST_TMP"
  run topology_resolve_arch "unknown-stack"
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

# ── topology_stack_host_alias ─────────────────────────────────────────────────

@test "topology_stack_host_alias: echoes the mapped alias" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
EOF
  export PROJECT_ROOT="$TEST_TMP"
  [ "$(topology_stack_host_alias "plane")" = "compass" ]
}

@test "topology_stack_host_alias: empty for unmapped stack" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa
EOF
  export PROJECT_ROOT="$TEST_TMP"
  [ -z "$(topology_stack_host_alias "unknown-stack")" ]
}

# ── tracked per-host env layer (env/hosts/<alias>.env) ─────────────────────────

@test "topology_apply_to_env: applies tracked host layer on the normal path, overriding base" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
EOF
  export PROJECT_ROOT="$TEST_TMP"
  unset VPS_HOST VPS_USER VPS_PORT VPS_SSH_KEY

  mkdir -p "$TEST_TMP/stacks/plane/env/hosts"
  cat > "$TEST_TMP/stacks/plane/env/hosts/compass.env" <<'EOF'
WEB_URL=https://plane.compass.local
MONITOR_REPLICAS=2
EOF

  export WEB_URL="https://base.example.com"
  topology_apply_to_env "plane" "$TEST_TMP/stacks/plane"

  [ "$WEB_URL" = "https://plane.compass.local" ]
  [ "$MONITOR_REPLICAS" = "2" ]
  # VPS_* connection defaults are still filled from topology
  [ "$VPS_HOST" = "compass.local" ]
}

@test "topology_apply_to_env: keys absent from the host layer are preserved from base" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
EOF
  export PROJECT_ROOT="$TEST_TMP"
  unset VPS_HOST VPS_USER VPS_PORT VPS_SSH_KEY

  mkdir -p "$TEST_TMP/stacks/plane/env/hosts"
  cat > "$TEST_TMP/stacks/plane/env/hosts/compass.env" <<'EOF'
WEB_URL=https://plane.compass.local
EOF

  export SOME_BASE_ONLY_VAR="untouched"
  topology_apply_to_env "plane" "$TEST_TMP/stacks/plane"

  [ "$SOME_BASE_ONLY_VAR" = "untouched" ]
  [ "$WEB_URL" = "https://plane.compass.local" ]
}

@test "topology_apply_to_env: no host layer file present is a no-op (no error)" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
EOF
  export PROJECT_ROOT="$TEST_TMP"
  unset VPS_HOST VPS_USER VPS_PORT VPS_SSH_KEY

  topology_apply_to_env "plane" "$TEST_TMP/stacks/plane"

  [ "$VPS_HOST" = "compass.local" ]
}

@test "topology_apply_host_layer: rejects a path-unsafe alias without erroring" {
  mkdir -p "$TEST_TMP/stacks/plane/env/hosts"
  run topology_apply_host_layer "plane" "../../etc" "$TEST_TMP/stacks/plane"
  [ "$status" -eq 0 ]
}

@test "topology_apply_host_override: tracked layer wins over legacy .<host>.env on overlapping keys" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa
EOF
  export PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks/plane/env/hosts"

  echo "WEB_URL=https://legacy.example.com" > "$TEST_TMP/stacks/plane/.compass.env"
  cat > "$TEST_TMP/stacks/plane/env/hosts/compass.env" <<'EOF'
WEB_URL=https://tracked.example.com
EOF

  topology_apply_host_override "plane" "compass" "$TEST_TMP/stacks/plane"

  [ "$WEB_URL" = "https://tracked.example.com" ]
}

@test "topology_apply_host_override: legacy .<host>.env still applied when tracked layer is absent" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa
EOF
  export PROJECT_ROOT="$TEST_TMP"

  mkdir -p "$TEST_TMP/stacks/plane"
  echo "WEB_URL=https://legacy.example.com" > "$TEST_TMP/stacks/plane/.compass.env"

  topology_apply_host_override "plane" "compass" "$TEST_TMP/stacks/plane"

  [ "$WEB_URL" = "https://legacy.example.com" ]
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

# ── topology_is_host_alias ────────────────────────────────────────────────────

@test "topology_is_host_alias: returns 0 for a defined host alias" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
harbor = deploy@harbor.example.com:22 ~/.ssh/id_rsa
EOF
  export PROJECT_ROOT="$TEST_TMP"
  topology_is_host_alias "harbor"
}

@test "topology_is_host_alias: returns 1 for an unknown name" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
[hosts]
harbor = deploy@harbor.example.com:22 ~/.ssh/id_rsa
EOF
  export PROJECT_ROOT="$TEST_TMP"
  run topology_is_host_alias "prod"
  [ "$status" -eq 1 ]
}

@test "topology_is_host_alias: returns 1 when no [hosts] section" {
  cat > "$TEST_TMP/strut.conf" <<'EOF'
REGISTRY_TYPE=none
EOF
  export PROJECT_ROOT="$TEST_TMP"
  run topology_is_host_alias "harbor"
  [ "$status" -eq 1 ]
}

# ── Property-Based Tests ──────────────────────────────────────────────────────

@test "Property: topology_resolve_host parses any valid host spec (100 iterations)" {
  for i in $(seq 1 100); do
    # Reset topology state
    _TOPO_HOSTS=()
    _TOPO_STACK_HOST=()
    _TOPO_LOADED=false

    # Generate random username (alphanumeric, 3-12 chars)
    local ulen=$(( (RANDOM % 10) + 3 ))
    local rand_user=""
    for c in $(seq 1 "$ulen"); do
      rand_user+=$(printf '%s' "abcdefghijklmnopqrstuvwxyz0123456789" | cut -c$(( (RANDOM % 36) + 1 )))
    done

    # Generate random hostname with dots and .local suffix
    local hlen=$(( (RANDOM % 8) + 3 ))
    local rand_host=""
    for c in $(seq 1 "$hlen"); do
      rand_host+=$(printf '%s' "abcdefghijklmnopqrstuvwxyz" | cut -c$(( (RANDOM % 26) + 1 )))
    done
    # Add a subdomain or .local
    if (( RANDOM % 2 == 0 )); then
      rand_host="${rand_host}.local"
    else
      rand_host="${rand_host}.$(printf '%s' "abcdefghij" | cut -c$(( (RANDOM % 10) + 1 )))$(printf '%s' "abcdefghij" | cut -c$(( (RANDOM % 10) + 1 )))$(printf '%s' "abcdefghij" | cut -c$(( (RANDOM % 10) + 1 ))).com"
    fi

    # Generate random port (1-65535)
    local rand_port=$(( (RANDOM % 65535) + 1 ))

    # Generate random key path
    local klen=$(( (RANDOM % 8) + 3 ))
    local rand_key="~/.ssh/"
    for c in $(seq 1 "$klen"); do
      rand_key+=$(printf '%s' "abcdefghijklmnopqrstuvwxyz_" | cut -c$(( (RANDOM % 27) + 1 )))
    done

    # Write config
    cat > "$TEST_TMP/strut.conf" <<EOF
[hosts]
testhost = ${rand_user}@${rand_host}:${rand_port} ${rand_key}

[stacks]
teststack = testhost
EOF

    export PROJECT_ROOT="$TEST_TMP"

    local user host port key
    read -r user host port key <<< "$(topology_resolve_host "teststack")"

    if [ "$user" != "$rand_user" ]; then
      fail "iteration $i: user mismatch: got '$user', expected '$rand_user'"
    fi
    if [ "$host" != "$rand_host" ]; then
      fail "iteration $i: host mismatch: got '$host', expected '$rand_host'"
    fi
    if [ "$port" != "$rand_port" ]; then
      fail "iteration $i: port mismatch: got '$port', expected '$rand_port'"
    fi
    if [ "$key" != "$rand_key" ]; then
      fail "iteration $i: key mismatch: got '$key', expected '$rand_key'"
    fi
  done
}

@test "Property: topology_apply_to_env never overwrites existing env vars (100 iterations)" {
  for i in $(seq 1 100); do
    # Reset topology state
    _TOPO_HOSTS=()
    _TOPO_STACK_HOST=()
    _TOPO_LOADED=false

    # Generate a random value for VPS_HOST
    local rand_val="existing-host-${RANDOM}-${RANDOM}"

    cat > "$TEST_TMP/strut.conf" <<EOF
[hosts]
node1 = deploy@server${RANDOM}.example.com:$(( (RANDOM % 65535) + 1 )) ~/.ssh/key${RANDOM}

[stacks]
mystack = node1
EOF

    export PROJECT_ROOT="$TEST_TMP"
    export VPS_HOST="$rand_val"
    unset VPS_USER VPS_PORT VPS_SSH_KEY

    topology_apply_to_env "mystack"

    if [ "$VPS_HOST" != "$rand_val" ]; then
      fail "iteration $i: VPS_HOST was overwritten: got '$VPS_HOST', expected '$rand_val'"
    fi
  done
}

@test "Property: topology_load is idempotent (100 iterations)" {
  for i in $(seq 1 100); do
    # Reset topology state
    _TOPO_HOSTS=()
    _TOPO_STACK_HOST=()
    _TOPO_LOADED=false

    # Generate random config with 1-3 hosts and stacks
    local num_hosts=$(( (RANDOM % 3) + 1 ))
    local conf_hosts=""
    local conf_stacks=""
    local aliases=()

    for h in $(seq 1 "$num_hosts"); do
      local alias="host${h}r${RANDOM}"
      aliases+=("$alias")
      conf_hosts+="${alias} = user${h}@node${h}.local:$(( (RANDOM % 65535) + 1 )) ~/.ssh/key${h}"$'\n'
      conf_stacks+="stack${h} = ${alias}"$'\n'
    done

    cat > "$TEST_TMP/strut.conf" <<EOF
[hosts]
${conf_hosts}
[stacks]
${conf_stacks}
EOF

    export PROJECT_ROOT="$TEST_TMP"

    # First load
    topology_load
    local hosts_after_first="${_TOPO_HOSTS[*]}"
    local stacks_after_first="${_TOPO_STACK_HOST[*]}"
    local loaded_after_first="$_TOPO_LOADED"

    # Second load (should be a no-op)
    topology_load
    local hosts_after_second="${_TOPO_HOSTS[*]}"
    local stacks_after_second="${_TOPO_STACK_HOST[*]}"
    local loaded_after_second="$_TOPO_LOADED"

    if [ "$hosts_after_first" != "$hosts_after_second" ]; then
      fail "iteration $i: _TOPO_HOSTS changed after second load"
    fi
    if [ "$stacks_after_first" != "$stacks_after_second" ]; then
      fail "iteration $i: _TOPO_STACK_HOST changed after second load"
    fi
    if [ "$loaded_after_first" != "$loaded_after_second" ]; then
      fail "iteration $i: _TOPO_LOADED changed after second load"
    fi
  done
}
