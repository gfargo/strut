#!/usr/bin/env bats
# ==================================================
# tests/test_proxy_config.bats — Property tests for pluggable reverse proxy config
# ==================================================
# Run:  bats tests/test_proxy_config.bats
# Feature: pluggable-reverse-proxy, Properties 1, 2

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_utils() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
}

_load_config() {
  _load_utils
  source "$CLI_ROOT/lib/config.sh"
}

# ── Helper: generate random alphanumeric string ──────────────────────────────

_rand_str() {
  local len="${1:-8}"
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$len" 2>/dev/null || true
}

# ── Property 1: Config parsing loads REVERSE_PROXY and defaults to nginx ─────
# Feature: pluggable-reverse-proxy, Property 1: Config parsing loads REVERSE_PROXY and defaults to nginx
# Validates: Requirements 1.1, 1.2

@test "Property 1: Config parsing loads REVERSE_PROXY and defaults to nginx (100 iterations)" {
  _load_config

  local keys=("REGISTRY_TYPE" "REGISTRY_HOST" "DEFAULT_ORG" "DEFAULT_BRANCH" "BANNER_TEXT" "REVERSE_PROXY")
  local defaults=("none" "" "" "main" "strut" "nginx")
  local valid_proxies=("nginx" "caddy")

  for i in $(seq 1 100); do
    local project_dir="$TEST_TMP/proxy_parse_$i"
    mkdir -p "$project_dir"
    local conf="$project_dir/strut.conf"
    > "$conf"

    local -a present_keys=()
    local -a present_vals=()
    local -a absent_keys=()
    local -a absent_defaults=()

    for idx in "${!keys[@]}"; do
      if (( RANDOM % 2 )); then
        local val
        if [ "${keys[$idx]}" = "REVERSE_PROXY" ]; then
          # Pick a valid proxy value when present
          val="${valid_proxies[$((RANDOM % 2))]}"
        else
          val="val_${RANDOM}_$(_rand_str 4)"
        fi
        echo "${keys[$idx]}=$val" >> "$conf"
        present_keys+=("${keys[$idx]}")
        present_vals+=("$val")
      else
        absent_keys+=("${keys[$idx]}")
        absent_defaults+=("${defaults[$idx]}")
      fi
    done

    (
      unset REGISTRY_TYPE REGISTRY_HOST DEFAULT_ORG DEFAULT_BRANCH BANNER_TEXT REVERSE_PROXY PROJECT_ROOT
      PROJECT_ROOT="$project_dir"
      export PROJECT_ROOT
      load_strut_config

      # Verify present keys have their specified values
      for idx in "${!present_keys[@]}"; do
        local actual="${!present_keys[$idx]}"
        [ "$actual" = "${present_vals[$idx]}" ]
      done

      # Verify absent keys have their defaults
      for idx in "${!absent_keys[@]}"; do
        local actual="${!absent_keys[$idx]}"
        [ "$actual" = "${absent_defaults[$idx]}" ]
      done
    )
  done
}


# ── Property 2: Invalid REVERSE_PROXY values are rejected ────────────────────
# Feature: pluggable-reverse-proxy, Property 2: Invalid REVERSE_PROXY values are rejected
# Validates: Requirements 1.3

@test "Property 2: Invalid REVERSE_PROXY values are rejected (100 iterations)" {
  _load_config

  for i in $(seq 1 100); do
    # Generate a random string that is NOT "nginx" or "caddy"
    local bad_val
    while true; do
      bad_val="$(_rand_str $(( (RANDOM % 12) + 1 )))"
      [[ "$bad_val" != "nginx" && "$bad_val" != "caddy" ]] && break
    done

    local project_dir="$TEST_TMP/bad_proxy_$i"
    mkdir -p "$project_dir"
    echo "REVERSE_PROXY=$bad_val" > "$project_dir/strut.conf"

    (
      unset REGISTRY_TYPE REGISTRY_HOST DEFAULT_ORG DEFAULT_BRANCH BANNER_TEXT REVERSE_PROXY PROJECT_ROOT
      PROJECT_ROOT="$project_dir"
      export PROJECT_ROOT
      run load_strut_config
      [ "$status" -ne 0 ]
    )
  done
}


# ── Helper: capture deploy_stack dry-run output with a given REVERSE_PROXY ───

_capture_proxy_deploy_dryrun() {
  local proxy_type="$1"

  _load_utils
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/deploy.sh"

  export REVERSE_PROXY="$proxy_type"
  export REGISTRY_TYPE="none"
  export DRY_RUN="true"

  # Create a minimal stack structure
  local stack_dir="$TEST_TMP/stacks/test-stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/docker-compose.yml" <<'YAML'
version: "3"
services:
  app:
    image: test:latest
YAML

  # Create a minimal env file
  local env_file="$TEST_TMP/.env.test"
  echo "VPS_HOST=10.0.0.1" > "$env_file"

  # Stub export_volume_paths
  export_volume_paths() { :; }

  # Stub docker compose version check
  docker() {
    if [ "$1" = "compose" ] && [ "$2" = "version" ]; then
      echo "Docker Compose version v2.20.0"
      return 0
    fi
    echo "docker $*"
    return 0
  }
  export -f docker

  export CLI_ROOT="$TEST_TMP"

  deploy_stack "test-stack" "$env_file" ""
}

# ── Property 7: Dry-run output shows correct proxy reload command per REVERSE_PROXY ──
# Feature: pluggable-reverse-proxy, Property 7: Dry-run output shows correct proxy reload command per REVERSE_PROXY
# Validates: Requirements 8.1, 8.2

@test "Property 7: Dry-run output shows correct proxy reload command per REVERSE_PROXY (100 iterations)" {
  local proxies=("nginx" "caddy")

  for i in $(seq 1 100); do
    local idx=$(( RANDOM % 2 ))
    local proxy="${proxies[$idx]}"

    run _capture_proxy_deploy_dryrun "$proxy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN]"* ]]

    case "$proxy" in
      nginx)
        [[ "$output" == *"nginx -s reload"* ]]
        ;;
      caddy)
        [[ "$output" == *"caddy reload"* ]]
        ;;
    esac
  done
}

# ── Helper: run scaffold with a given REVERSE_PROXY and return target dir ────

_scaffold_with_proxy() {
  local proxy_type="$1"
  local stack_name="$2"

  _load_utils
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/cmd_scaffold.sh"

  export REVERSE_PROXY="$proxy_type"
  export PROJECT_ROOT="$TEST_TMP"
  export STRUT_HOME="$CLI_ROOT"

  cmd_scaffold "$stack_name"
}

# ── Property 3: Scaffold creates correct proxy directory per REVERSE_PROXY ───
# Feature: pluggable-reverse-proxy, Property 3: Scaffold creates correct proxy directory per REVERSE_PROXY
# Validates: Requirements 3.1, 3.2, 3.3

@test "Property 3: Scaffold creates correct proxy directory per REVERSE_PROXY (100 iterations)" {
  local proxies=("nginx" "caddy")

  for i in $(seq 1 100); do
    local idx=$(( RANDOM % 2 ))
    local proxy="${proxies[$idx]}"
    local stack_name="proxy-test-${i}-${RANDOM}"

    run _scaffold_with_proxy "$proxy" "$stack_name"
    [ "$status" -eq 0 ]

    local target="$TEST_TMP/stacks/$stack_name"

    case "$proxy" in
      nginx)
        # Req 3.1: nginx/ directory with nginx.conf and conf.d/
        [ -d "$target/nginx" ]
        [ -d "$target/nginx/conf.d" ]
        [ -f "$target/nginx/nginx.conf" ]
        # Must NOT have caddy directory
        [ ! -d "$target/caddy" ]
        # Next steps output references nginx
        [[ "$output" == *"nginx"* ]]
        ;;
      caddy)
        # Req 3.2: caddy/ directory with Caddyfile
        [ -d "$target/caddy" ]
        [ -f "$target/caddy/Caddyfile" ]
        # Req 3.4: Caddyfile contains placeholder reverse_proxy block
        grep -q "reverse_proxy" "$target/caddy/Caddyfile"
        # Must NOT have nginx directory
        [ ! -d "$target/nginx" ]
        # Next steps output references caddy
        [[ "$output" == *"caddy"* ]]
        ;;
    esac
  done
}

# ── Helper: get drift tracked files for a given REVERSE_PROXY ────────────────

_get_drift_tracked_files_for_proxy() {
  local proxy_type="$1"

  _load_utils
  source "$CLI_ROOT/lib/drift.sh"

  export REVERSE_PROXY="$proxy_type"
  drift_get_tracked_files
}

# ── Property 4: Drift tracked files include correct proxy config per REVERSE_PROXY ──
# Feature: pluggable-reverse-proxy, Property 4: Drift tracked files include correct proxy config per REVERSE_PROXY
# Validates: Requirements 5.1, 5.2

@test "Property 4: Drift tracked files include correct proxy config per REVERSE_PROXY (100 iterations)" {
  local proxies=("nginx" "caddy")

  for i in $(seq 1 100); do
    local idx=$(( RANDOM % 2 ))
    local proxy="${proxies[$idx]}"

    run _get_drift_tracked_files_for_proxy "$proxy"
    [ "$status" -eq 0 ]

    case "$proxy" in
      nginx)
        # Req 5.1: nginx tracked files include nginx/nginx.conf
        [[ "$output" == *"nginx/nginx.conf"* ]]
        # Must NOT include caddy config
        [[ "$output" != *"caddy/Caddyfile"* ]]
        ;;
      caddy)
        # Req 5.2: caddy tracked files include caddy/Caddyfile
        [[ "$output" == *"caddy/Caddyfile"* ]]
        # Must NOT include nginx config
        [[ "$output" != *"nginx/nginx.conf"* ]]
        ;;
    esac

    # Both should always include base files
    [[ "$output" == *"docker-compose.yml"* ]]
    [[ "$output" == *".env.template"* ]]
    [[ "$output" == *"backup.conf"* ]]
    [[ "$output" == *"repos.conf"* ]]
    [[ "$output" == *"volume.conf"* ]]
  done
}

# ── Helper: load health.sh with stubs and capture checked ports ──────────────

_load_health_stubbed() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  source "$CLI_ROOT/lib/health.sh"

  # Reset health state
  HEALTH_OVERALL="healthy"
  HEALTH_PASSED=0
  HEALTH_FAILED=0
  HEALTH_WARNED=0
  HEALTH_JSON_OUTPUT=false

  # Stub ss to report all ports as listening
  ss() { echo ":99999 "; }
  export -f ss
  # Stub ping to succeed
  ping() { return 0; }
  export -f ping
}

# ── Property 5: Health engine checks correct default ports per REVERSE_PROXY ─
# Feature: pluggable-reverse-proxy, Property 5: Health engine checks correct default ports per REVERSE_PROXY
# Validates: Requirements 7.1, 7.2

@test "Property 5: Health engine checks correct default ports per REVERSE_PROXY (100 iterations)" {
  _load_health_stubbed

  local proxies=("nginx" "caddy")

  for i in $(seq 1 100); do
    local idx=$(( RANDOM % 2 ))
    local proxy="${proxies[$idx]}"

    # Ensure no PROXY_PORTS override
    unset PROXY_PORTS

    export REVERSE_PROXY="$proxy"

    # Create a minimal stack dir (no services.conf so only proxy ports are checked)
    local stack_dir="$TEST_TMP/health_default_$i"
    mkdir -p "$stack_dir"

    # Reset health state
    HEALTH_OVERALL="healthy"
    HEALTH_PASSED=0
    HEALTH_FAILED=0
    HEALTH_WARNED=0

    local output
    output=$(health_check_network "$stack_dir" 2>&1)

    case "$proxy" in
      nginx)
        # Req 7.1: port 80 must be included
        [[ "$output" == *"Port 80"* ]] || {
          echo "FAIL iteration $i (nginx): Port 80 not found in output: $output" >&2
          return 1
        }
        ;;
      caddy)
        # Req 7.2: both port 80 and 443 must be included
        [[ "$output" == *"Port 80"* ]] || {
          echo "FAIL iteration $i (caddy): Port 80 not found in output: $output" >&2
          return 1
        }
        [[ "$output" == *"Port 443"* ]] || {
          echo "FAIL iteration $i (caddy): Port 443 not found in output: $output" >&2
          return 1
        }
        ;;
    esac
  done
}

# ── Property 6: PROXY_PORTS override replaces default proxy ports ────────────
# Feature: pluggable-reverse-proxy, Property 6: PROXY_PORTS override replaces default proxy ports
# Validates: Requirements 7.3

@test "Property 6: PROXY_PORTS override replaces default proxy ports (100 iterations)" {
  _load_health_stubbed

  local proxies=("nginx" "caddy")

  for i in $(seq 1 100); do
    local idx=$(( RANDOM % 2 ))
    local proxy="${proxies[$idx]}"

    export REVERSE_PROXY="$proxy"

    # Generate 1-4 random ports for PROXY_PORTS override
    local num_ports=$(( (RANDOM % 4) + 1 ))
    local -a override_ports=()
    for p in $(seq 1 "$num_ports"); do
      override_ports+=("$(( (RANDOM % 9000) + 1024 ))")
    done
    export PROXY_PORTS="${override_ports[*]}"

    # Create a minimal stack dir (no services.conf)
    local stack_dir="$TEST_TMP/health_override_$i"
    mkdir -p "$stack_dir"

    # Reset health state
    HEALTH_OVERALL="healthy"
    HEALTH_PASSED=0
    HEALTH_FAILED=0
    HEALTH_WARNED=0

    local output
    output=$(health_check_network "$stack_dir" 2>&1)

    # Verify each override port appears in the output
    for port in "${override_ports[@]}"; do
      [[ "$output" == *"Port $port"* ]] || {
        echo "FAIL iteration $i: override port $port not found in output: $output" >&2
        return 1
      }
    done

    # Verify default proxy ports are NOT present (unless they happen to be in override_ports)
    # For caddy, port 443 should not appear unless it's in override_ports
    # Use word-boundary check to avoid false matches (e.g. "Port 4437" matching "Port 443")
    if [[ "$proxy" == "caddy" ]]; then
      local has_443=false
      for port in "${override_ports[@]}"; do
        [[ "$port" == "443" ]] && { has_443=true; break; }
      done
      if ! $has_443; then
        if echo "$output" | grep -qw "Port 443"; then
          echo "FAIL iteration $i (caddy): default port 443 should not appear when PROXY_PORTS is set: $output" >&2
          return 1
        fi
      fi
    fi
  done

  unset PROXY_PORTS
}
