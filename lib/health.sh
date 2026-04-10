#!/usr/bin/env bash
# ==================================================
# lib/health.sh — Health check framework
# ==================================================
# Requires: lib/utils.sh sourced first

# ── State ─────────────────────────────────────────────────────────────────────
set -euo pipefail

HEALTH_OVERALL="healthy"
HEALTH_PASSED=0
HEALTH_FAILED=0
HEALTH_WARNED=0
HEALTH_JSON_RESULTS="[]"
HEALTH_JSON_OUTPUT=false

# ── Internal helpers ──────────────────────────────────────────────────────────

# _health_record <status> <name> <message> [details] — records a single health check result
_health_record() {
  local status="$1" name="$2" message="$3" details="${4:-}"
  if $HEALTH_JSON_OUTPUT; then
    HEALTH_JSON_RESULTS=$(echo "$HEALTH_JSON_RESULTS" | \
      jq -c ". += [{\"name\": \"$name\", \"status\": \"$status\", \"message\": \"$message\", \"details\": \"$details\"}]")
    return
  fi
  case "$status" in
    pass)
      echo -e "${GREEN}✓${NC} $name: $message"
      HEALTH_PASSED=$((HEALTH_PASSED + 1))
      ;;
    fail)
      echo -e "${RED}✗${NC} $name: $message"
      HEALTH_FAILED=$((HEALTH_FAILED + 1))
      HEALTH_OVERALL="unhealthy"
      ;;
    warn)
      echo -e "${YELLOW}⚠${NC} $name: $message"
      HEALTH_WARNED=$((HEALTH_WARNED + 1))
      [ "$HEALTH_OVERALL" = "healthy" ] && HEALTH_OVERALL="degraded"
      ;;
    skip)
      echo -e "  ${BLUE}–${NC} $name: $message"
      ;;
  esac
  [ -n "$details" ] && echo "  Details: $details"
}

# ── Check functions ───────────────────────────────────────────────────────────

# health_check_docker
#
# Verifies the Docker daemon is running and Docker Compose is installed.
# Records pass/fail results via _health_record.
#
# Returns: 0 on success, 1 if Docker or Compose is missing
# Side effects: Writes health check results to module-level state
health_check_docker() {
  $HEALTH_JSON_OUTPUT || echo -e "${BLUE}Checking Docker...${NC}"
  if docker info > /dev/null 2>&1; then
    _health_record pass "Docker Daemon" "Running"
  else
    _health_record fail "Docker Daemon" "Not running"
    return 1
  fi
  if docker compose version > /dev/null 2>&1; then
    local ver
    # grep -oP is GNU-only; use -Eo for macOS/BSD compatibility
    ver=$(docker compose version --short 2>/dev/null || docker compose version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    _health_record pass "Docker Compose" "Installed (v$ver)"
  else
    _health_record fail "Docker Compose" "Not installed"
    return 1
  fi
  $HEALTH_JSON_OUTPUT || echo ""
}

# health_check_containers <compose_cmd> <compose_file>
#
# Checks the state and health of all containers in a compose stack.
# Reports running/stopped status and Docker health check results per container.
#
# Args:
#   compose_cmd   — Full docker compose command prefix (e.g. "docker compose -f ... -p ...")
#   compose_file  — Path to the compose file (validated for existence)
#
# Returns: 0 on success, 1 if compose file missing or no containers running
# Side effects: Writes health check results to module-level state
health_check_containers() {
  local compose_cmd="$1"
  local compose_file="$2"
  $HEALTH_JSON_OUTPUT || echo -e "${BLUE}Checking Containers...${NC}"

  [ -f "$compose_file" ] || { _health_record fail "Compose File" "Not found: $compose_file"; return 1; }

  local containers
  containers=$($compose_cmd ps --format json 2>/dev/null || echo "[]")
  if [ "$containers" = "[]" ]; then
    _health_record fail "Containers" "No containers running"
    return 1
  fi

  echo "$containers" | jq -r '.[] | "\(.Name)|\(.State)|\(.Health)"' 2>/dev/null | \
  while IFS='|' read -r name state health; do
    if [ "$state" = "running" ]; then
      if [ "$health" = "healthy" ] || [ -z "$health" ]; then
        _health_record pass "Container: $name" "Running"
      else
        _health_record warn "Container: $name" "Running but health: $health"
      fi
    else
      _health_record fail "Container: $name" "State: $state"
    fi
  done
  $HEALTH_JSON_OUTPUT || echo ""
}

# health_check_application <stack_dir>
#
# Dynamically discovers application services from the stack's services.conf.
# Scans for all *_PORT variables (excluding DB_* prefixed), then for each
# checks if a matching *_HEALTH_PATH exists → HTTP probe; otherwise → TCP check.
#
# Args:
#   stack_dir — Path to the stack directory containing services.conf
#
# Side effects: Writes health check results to module-level state
health_check_application() {
  local stack_dir="${1:-}"
  local conf="${stack_dir:+$stack_dir/services.conf}"
  $HEALTH_JSON_OUTPUT || echo -e "${BLUE}Checking Application Services...${NC}"

  if [ -z "$conf" ] || [ ! -f "$conf" ]; then
    _health_record warn "Services" "No services.conf found — skipping application health checks"
    $HEALTH_JSON_OUTPUT || echo ""
    return 0
  fi

  local found_service=false

  # Cache conf content to avoid reading the same file in the loop and grep (SC2094)
  local conf_content
  conf_content=$(cat "$conf")

  # Discover all *_PORT variables (excluding DB_* prefixed)
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    # Strip whitespace
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    # Match *_PORT but not DB_*
    [[ "$key" == DB_* ]] && continue
    [[ "$key" != *_PORT ]] && continue

    found_service=true
    local port="$value"
    # Derive service name: strip _PORT suffix
    local svc_prefix="${key%_PORT}"
    local svc_name
    svc_name=$(echo "$svc_prefix" | tr '[:upper:]_' '[:lower:]-')
    local health_path_key="${svc_prefix}_HEALTH_PATH"

    # Look up the health path from cached conf content
    local health_path=""
    health_path=$(echo "$conf_content" | grep -E "^${health_path_key}=" 2>/dev/null | head -1 | cut -d'=' -f2- | xargs) || true

    if [ -n "$health_path" ]; then
      # HTTP probe
      if curl -s -f --max-time 5 "http://localhost:${port}${health_path}" &>/dev/null; then
        _health_record pass "${svc_name}:${port}" "healthy"
      else
        _health_record fail "${svc_name}:${port}" "no response on ${health_path}"
      fi
    else
      # TCP check
      if (echo > "/dev/tcp/localhost/$port") 2>/dev/null; then
        _health_record pass "${svc_name}:${port}" "listening (TCP)"
      elif ss -tuln 2>/dev/null | grep -q ":${port} " || netstat -tuln 2>/dev/null | grep -q ":${port} "; then
        _health_record pass "${svc_name}:${port}" "listening (TCP)"
      else
        _health_record fail "${svc_name}:${port}" "not listening"
      fi
    fi
  done <<< "$conf_content"

  if ! $found_service; then
    _health_record warn "Services" "No *_PORT entries found in services.conf"
  fi

  $HEALTH_JSON_OUTPUT || echo ""
}

# health_check_databases <compose_cmd> <stack_dir>
#
# Dynamically dispatches database health checks based on DB_* flags in services.conf.
# DB_POSTGRES=true → pg_isready, DB_NEO4J=true → HTTP check, DB_MYSQL=true → mysqladmin ping.
# Skips DB checks when no DB_* flags are set.
#
# Args:
#   compose_cmd — Full docker compose command prefix
#   stack_dir   — Path to the stack directory containing services.conf
#
# Side effects: Writes health check results to module-level state
health_check_databases() {
  local compose_cmd="$1"
  local stack_dir="${2:-}"
  local conf="${stack_dir:+$stack_dir/services.conf}"
  $HEALTH_JSON_OUTPUT || echo -e "${BLUE}Checking Databases...${NC}"

  if [ -z "$conf" ] || [ ! -f "$conf" ]; then
    _health_record skip "Databases" "No services.conf — skipping database checks"
    $HEALTH_JSON_OUTPUT || echo ""
    return 0
  fi

  local found_db=false

  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    # Match DB_*=true flags
    [[ "$key" != DB_* ]] && continue
    [[ "$value" != "true" ]] && continue

    found_db=true
    local db_type="${key#DB_}"

    case "$db_type" in
      POSTGRES)
        if $compose_cmd exec -T postgres pg_isready -U "${POSTGRES_USER:-postgres}" > /dev/null 2>&1; then
          _health_record pass "PostgreSQL" "Ready"
        else
          _health_record fail "PostgreSQL" "Not ready"
        fi
        ;;
      NEO4J)
        local neo4j_port="${NEO4J_BROWSER_PORT:-7474}"
        if curl -s -f "http://localhost:${neo4j_port}" > /dev/null 2>&1; then
          _health_record pass "Neo4j" "Accessible (:${neo4j_port})"
        else
          _health_record fail "Neo4j" "Not accessible (:${neo4j_port})"
        fi
        ;;
      MYSQL)
        if $compose_cmd exec -T mysql mysqladmin ping -u "${MYSQL_USER:-root}" --silent > /dev/null 2>&1; then
          _health_record pass "MySQL" "Ready"
        else
          _health_record fail "MySQL" "Not ready"
        fi
        ;;
      REDIS)
        if $compose_cmd exec -T redis redis-cli ping > /dev/null 2>&1; then
          _health_record pass "Redis" "Ready"
        else
          _health_record fail "Redis" "Not ready"
        fi
        ;;
      *)
        _health_record warn "$db_type" "Unknown database type — no health check available"
        ;;
    esac
  done < "$conf"

  if ! $found_db; then
    _health_record skip "Databases" "No DB_* flags in services.conf — skipping"
  fi

  $HEALTH_JSON_OUTPUT || echo ""
}

# health_check_resources
#
# Checks host resource utilisation: disk space, memory, and CPU load.
# Thresholds: <80% pass, 80-90% warn, ≥90% fail.
#
# Side effects: Writes health check results to module-level state
health_check_resources() {
  $HEALTH_JSON_OUTPUT || echo -e "${BLUE}Checking Resources...${NC}"

  local disk_usage mem_usage load cpu_count load_percent

  disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
  if   [ "$disk_usage" -lt 80 ]; then _health_record pass "Disk Space" "${disk_usage}% used"
  elif [ "$disk_usage" -lt 90 ]; then _health_record warn "Disk Space" "${disk_usage}% used (getting full)"
  else                                  _health_record fail "Disk Space" "${disk_usage}% used (critical)"
  fi

  mem_usage=$(free | awk 'NR==2 {printf "%.0f", $3/$2 * 100}')
  if   [ "$mem_usage" -lt 80 ]; then _health_record pass "Memory Usage" "${mem_usage}% used"
  elif [ "$mem_usage" -lt 90 ]; then _health_record warn "Memory Usage" "${mem_usage}% used (high)"
  else                                 _health_record fail "Memory Usage" "${mem_usage}% used (critical)"
  fi

  load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
  cpu_count=$(nproc 2>/dev/null || echo 1)
  load_percent=$(echo "$load $cpu_count" | awk '{printf "%.0f", ($1/$2)*100}')
  if   [ "$load_percent" -lt 70 ]; then _health_record pass "CPU Load" "${load} (${load_percent}% of capacity)"
  elif [ "$load_percent" -lt 90 ]; then _health_record warn "CPU Load" "${load} (${load_percent}% of capacity)"
  else                                   _health_record fail "CPU Load" "${load} (${load_percent}% of capacity)"
  fi

  $HEALTH_JSON_OUTPUT || echo ""
}

# health_check_network <stack_dir>
#
# Dynamically reads all *_PORT entries from services.conf and verifies each
# declared port is listening. Always includes port 80 (reverse proxy).
# Also checks outbound internet connectivity.
#
# Args:
#   stack_dir — Path to the stack directory containing services.conf
#
# Side effects: Writes health check results to module-level state
health_check_network() {
  local stack_dir="${1:-}"
  local conf="${stack_dir:+$stack_dir/services.conf}"
  $HEALTH_JSON_OUTPUT || echo -e "${BLUE}Checking Network...${NC}"

  # Collect ports: always start with 80
  local -a ports=(80)

  if [ -n "$conf" ] && [ -f "$conf" ]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
      key=$(echo "$key" | xargs)
      value=$(echo "$value" | xargs)
      [[ "$key" == DB_* ]] && continue
      [[ "$key" != *_PORT ]] && continue
      # Avoid duplicates with port 80
      [[ "$value" == "80" ]] && continue
      ports+=("$value")
    done < "$conf"
  fi

  for port in "${ports[@]}"; do
    if ss -tuln 2>/dev/null | grep -q ":${port} " || netstat -tuln 2>/dev/null | grep -q ":${port} "; then
      _health_record pass "Port $port" "Listening"
    else
      _health_record warn "Port $port" "Not listening"
    fi
  done

  if ping -c 1 8.8.8.8 > /dev/null 2>&1; then
    _health_record pass "Internet" "Connected"
  else
    _health_record fail "Internet" "No connectivity"
  fi

  $HEALTH_JSON_OUTPUT || echo ""
}

# health_run_all <stack> <compose_cmd> <compose_file> [--json]
#
# Runs the full health check suite (Docker, containers, application, databases,
# resources, network) and prints a summary. Pass --json for machine-readable output.
#
# Args:
#   stack             — Stack name (e.g. "my-stack")
#   compose_cmd       — Full docker compose command prefix
#   compose_file      — Path to the compose file
#   --json            — Output results as JSON instead of human-readable text
#
# Requires env: CLI_ROOT (default: auto-detected from script location)
# Returns: 0 healthy, 1 degraded, 2 unhealthy
# Side effects: Resets and populates module-level HEALTH_* counters; prints to stdout
health_run_all() {
  local stack="$1"
  local compose_cmd="$2"
  local compose_file="$3"
  local json_mode="${4:-}"

  [ "$json_mode" = "--json" ] && HEALTH_JSON_OUTPUT=true

  # Resolve stack directory for services.conf discovery
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"

  # Load stack-specific service config (ports, paths, etc.)
  load_services_conf "$stack_dir"

  # Reset counters
  HEALTH_OVERALL="healthy"
  HEALTH_PASSED=0
  HEALTH_FAILED=0
  HEALTH_WARNED=0
  HEALTH_JSON_RESULTS="[]"

  if ! $HEALTH_JSON_OUTPUT; then
    echo -e "${BLUE}=================================================="
    echo -e "  Health Check: $stack"
    echo -e "==================================================${NC}"
    echo ""
  fi

  health_check_docker
  health_check_containers "$compose_cmd" "$compose_file"
  health_check_application "$stack_dir"
  health_check_databases "$compose_cmd" "$stack_dir"
  health_check_resources
  health_check_network "$stack_dir"

  if $HEALTH_JSON_OUTPUT; then
    echo "{\"stack\": \"$stack\", \"overall_status\": \"$HEALTH_OVERALL\", \"checks\": $HEALTH_JSON_RESULTS, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | jq '.'
  else
    echo -e "${BLUE}=================================================="
    echo -e "  Summary"
    echo -e "==================================================${NC}"
    echo ""
    echo "Overall Status: $HEALTH_OVERALL"
    echo "Passed:  $HEALTH_PASSED"
    echo "Warning: $HEALTH_WARNED"
    echo "Failed:  $HEALTH_FAILED"
    echo ""
    case "$HEALTH_OVERALL" in
      healthy)   echo -e "${GREEN}✓ All systems operational${NC}" ;;
      degraded)  echo -e "${YELLOW}⚠ System degraded — some issues detected${NC}" ;;
      unhealthy) echo -e "${RED}✗ System unhealthy — critical issues detected${NC}" ;;
    esac
  fi

  case "$HEALTH_OVERALL" in
    healthy)   return 0 ;;
    degraded)  return 1 ;;
    unhealthy) return 2 ;;
  esac
}
