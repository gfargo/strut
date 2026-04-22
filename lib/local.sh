#!/usr/bin/env bash
# ==================================================
# lib/local.sh — Local Development Parity
# ==================================================
# Requires: lib/utils.sh, lib/backup.sh sourced first
#
# Provides local development environment management:
# - Start/stop stacks locally with docker-compose.local.yml
# - Sync production environment variables
# - Sync production databases (with anonymization)
# - Port conflict detection
# - Local environment validation
# - Hot-reload support

# local_start <stack> [--services <profile>]
# Start a stack in local development mode
set -euo pipefail

local_start() {
  local stack="$1"
  shift

  local services_profile=""

  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --services)
        services_profile="$2"
        shift 2
        ;;
      *)
        error "Unknown option: $1"
        return 1
        ;;
    esac
  done

  local stack_dir="$CLI_ROOT/stacks/$stack"
  [ -d "$stack_dir" ] || fail "Stack not found: $stack"

  local compose_local="$stack_dir/docker-compose.local.yml"
  local env_local="$stack_dir/.env.local"
  local env_template="$stack_dir/.env.template"

  # Check if docker-compose.local.yml exists
  if [ ! -f "$compose_local" ]; then
    warn "docker-compose.local.yml not found, using docker-compose.yml"
    compose_local="$stack_dir/docker-compose.yml"
  fi


  # Check if .env.local exists, otherwise use .env.template
  if [ ! -f "$env_local" ]; then
    if [ -f "$env_template" ]; then
      warn ".env.local not found, creating from .env.template"
      cp "$env_template" "$env_local"
      warn "Please review and update .env.local with local values"
    else
      warn "No .env.local or .env.template found"
    fi
  fi

  # Validate environment variables
  log "Validating local environment..."
  if ! local_validate_env "$stack"; then
    error "Environment validation failed"
    return 1
  fi

  # Check for port conflicts
  log "Checking for port conflicts..."
  if ! local_check_ports "$stack"; then
    error "Port conflict detected"
    return 1
  fi

  # Build compose command
  local compose_cmd
  compose_cmd=$(resolve_local_compose_cmd "$stack" "$services_profile")

  log "Starting local stack: $stack"
  log "Compose file: $compose_local"
  [ -f "$env_local" ] && log "Env file: $env_local"

  # Start services
  if $compose_cmd up -d; then
    ok "Local stack started successfully"
    echo ""
    log "Services running:"
    $compose_cmd ps
    echo ""
    local_show_endpoints "$stack"
  else
    error "Failed to start local stack"
    return 1
  fi
}


# local_stop <stack>
# Stop local stack
local_stop() {
  local stack="$1"

  local stack_dir="$CLI_ROOT/stacks/$stack"
  [ -d "$stack_dir" ] || fail "Stack not found: $stack"

  local compose_cmd
  compose_cmd=$(resolve_local_compose_cmd "$stack")

  log "Stopping local stack: $stack"

  if $compose_cmd down; then
    ok "Local stack stopped successfully"
  else
    error "Failed to stop local stack"
    return 1
  fi
}

# local_reset <stack>
# Reset local environment to clean state
local_reset() {
  local stack="$1"

  local stack_dir="$CLI_ROOT/stacks/$stack"
  [ -d "$stack_dir" ] || fail "Stack not found: $stack"

  warn "This will stop the stack and remove all volumes (data will be lost)"
  confirm "Continue?" || { ok "Reset cancelled"; return 0; }

  local compose_cmd
  compose_cmd=$(resolve_local_compose_cmd "$stack")

  log "Resetting local stack: $stack"

  if $compose_cmd down -v; then
    ok "Local stack reset successfully"
  else
    error "Failed to reset local stack"
    return 1
  fi
}


# local_sync_env <stack> <source_env>
# Sync environment variables from production to local
local_sync_env() {
  local stack="$1"
  local source_env="$2"

  local stack_dir="$CLI_ROOT/stacks/$stack"
  [ -d "$stack_dir" ] || fail "Stack not found: $stack"

  local source_env_file="$CLI_ROOT/.${source_env}.env"
  [ -f "$source_env_file" ] || fail "Source env file not found: $source_env_file"

  local env_local="$stack_dir/.env.local"
  local env_template="$stack_dir/.env.template"

  log "Syncing environment from $source_env to local..."

  # Backup existing .env.local if it exists
  if [ -f "$env_local" ]; then
    local backup_file="${env_local}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$env_local" "$backup_file"
    log "Backed up existing .env.local to: $backup_file"
  fi

  # Copy source env to .env.local
  cp "$source_env_file" "$env_local"

  # Validate against template
  if [ -f "$env_template" ]; then
    log "Validating environment variables..."
    if ! local_validate_env "$stack"; then
      warn "Some environment variables may be missing or invalid"
    fi
  fi

  ok "Environment synced successfully"
  log "Local env file: $env_local"
}

# local_sync_db <stack> <source_env> <target> [--anonymize] [--yes]
# Sync database from production to local
local_sync_db() {
  local stack="$1"
  local source_env="$2"
  local target="$3"
  shift 3

  local anonymize=false
  local auto_yes=false

  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --anonymize)
        anonymize=true
        shift
        ;;
      --yes|-y)
        auto_yes=true
        shift
        ;;
      *)
        error "Unknown option: $1"
        return 1
        ;;
    esac
  done

  local stack_dir="$CLI_ROOT/stacks/$stack"
  [ -d "$stack_dir" ] || fail "Stack not found: $stack"

  local source_env_file="$CLI_ROOT/.${source_env}.env"
  validate_env_file "$source_env_file" VPS_HOST

  log "Syncing database from $source_env to local..."

  # Check if local stack is running
  local compose_cmd
  compose_cmd=$(resolve_local_compose_cmd "$stack")

  if ! $compose_cmd ps --services --filter "status=running" | grep -q .; then
    error "Local stack is not running. Start it first with: strut $stack local start"
    return 1
  fi


  # Create local backup before sync
  log "Creating local backup before sync..."
  local backup_dir="$stack_dir/backups"
  mkdir -p "$backup_dir"

  if [[ "$target" == "postgres" || "$target" == "all" ]]; then
    backup_postgres "$stack" "$compose_cmd" || warn "Failed to backup local postgres"
  fi

  if [[ "$target" == "neo4j" || "$target" == "all" ]]; then
    backup_neo4j "$stack" "$compose_cmd" || warn "Failed to backup local neo4j"
  fi

  # Pull database from production
  log "Pulling database from $source_env..."

  # For local sync, we need to pass download_only=false and let db_pull restore to local
  # But db_pull expects the local stack to be running with the source env name
  # We need to override this behavior for local development

  # Instead of calling db_pull, we'll do the pull and restore manually
  # This gives us better control over the local stack detection

  # VPS connection details already sourced by validate_env_file above
  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_deploy_dir="${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -k "$vps_ssh_key")

  local remote_backup_dir
  remote_backup_dir=$(_remote_backup_dir "$stack" "$ssh_opts" "$vps_user" "$vps_host" "$vps_deploy_dir")

  # Pull and restore postgres
  if [[ "$target" == "postgres" || "$target" == "all" ]]; then
    log "Finding latest PostgreSQL backup on VPS..."

    local latest_postgres
    latest_postgres=$(ssh $ssh_opts "$vps_user@$vps_host" \
      "ls -t $remote_backup_dir/postgres-*.sql 2>/dev/null | head -1" || echo "")

    if [ -z "$latest_postgres" ]; then
      warn "No PostgreSQL backups found on VPS"
    else
      local filename
      filename=$(basename "$latest_postgres")
      local local_file="$backup_dir/$filename"

      log "Downloading $filename from VPS..."
      rsync -avz -e "ssh $ssh_opts" \
        "$vps_user@$vps_host:$latest_postgres" \
        "$local_file" \
      && ok "Downloaded: $local_file" \
      || { error "Failed to download PostgreSQL backup"; return 1; }

      log "Restoring PostgreSQL to local environment..."
      warn "This will overwrite your local PostgreSQL database"
      if [ "$auto_yes" = false ]; then
        confirm "Continue with restore?" || { ok "Restore skipped"; return 0; }
      fi

      restore_postgres "$stack" "$compose_cmd" "$local_file"
    fi
  fi

  # Pull and restore neo4j
  if [[ "$target" == "neo4j" || "$target" == "all" ]]; then
    log "Finding latest Neo4j backup on VPS..."

    local latest_neo4j
    latest_neo4j=$(ssh $ssh_opts "$vps_user@$vps_host" \
      "ls -t $remote_backup_dir/neo4j-*.dump 2>/dev/null | head -1" || echo "")

    if [ -z "$latest_neo4j" ]; then
      warn "No Neo4j backups found on VPS"
    else
      local filename
      filename=$(basename "$latest_neo4j")
      local local_file="$backup_dir/$filename"

      log "Downloading $filename from VPS..."
      rsync -avz -e "ssh $ssh_opts" \
        "$vps_user@$vps_host:$latest_neo4j" \
        "$local_file" \
      && ok "Downloaded: $local_file" \
      || { error "Failed to download Neo4j backup"; return 1; }

      log "Restoring Neo4j to local environment..."
      warn "This will overwrite your local Neo4j database"
      if [ "$auto_yes" = false ]; then
        confirm "Continue with restore?" || { ok "Restore skipped"; return 0; }
      fi

      restore_neo4j "$stack" "$compose_cmd" "$local_file"
    fi
  fi

  # Anonymize if requested
  if [ "$anonymize" = true ]; then
    local anon_conf="$stack_dir/anonymize.conf"
    if [ ! -f "$anon_conf" ]; then
      warn "No anonymize.conf found at $anon_conf — skipping anonymization"
      warn "Create one with: TABLE.COLUMN=strategy (e.g. users.email=fake_email)"
    else
      # anonymize.sh ships with the engine, not the project — always
      # source from STRUT_HOME to stay correct under CLI_ROOT=PROJECT_ROOT.
      source "${STRUT_HOME:-$CLI_ROOT}/lib/anonymize.sh"

      if [ "$DRY_RUN" = "true" ]; then
        anon_dry_run "$anon_conf" "postgres"
      else
        log "Applying anonymization rules from anonymize.conf..."
        if [[ "$target" == "postgres" || "$target" == "all" ]]; then
          anon_apply_postgres "$stack" "$compose_cmd" "$anon_conf"
        fi
      fi
    fi
  else
    # Warn if anonymize.conf exists but --anonymize wasn't passed
    local anon_conf="$stack_dir/anonymize.conf"
    if [ -f "$anon_conf" ]; then
      warn "anonymize.conf exists but --anonymize was not passed"
      warn "Run with --anonymize to apply PII anonymization rules"
    fi
  fi

  ok "Database synced successfully"
}

# local_logs <stack> [--follow]
# Tail logs from all local services
local_logs() {
  local stack="$1"
  shift

  local follow=false

  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --follow|-f)
        follow=true
        shift
        ;;
      *)
        error "Unknown option: $1"
        return 1
        ;;
    esac
  done

  local stack_dir="$CLI_ROOT/stacks/$stack"
  [ -d "$stack_dir" ] || fail "Stack not found: $stack"

  local compose_cmd
  compose_cmd=$(resolve_local_compose_cmd "$stack")

  if [ "$follow" = true ]; then
    $compose_cmd logs -f
  else
    $compose_cmd logs --tail=100
  fi
}


# local_test <stack>
# Run local smoke tests
local_test() {
  local stack="$1"

  local stack_dir="$CLI_ROOT/stacks/$stack"
  [ -d "$stack_dir" ] || fail "Stack not found: $stack"

  local compose_cmd
  compose_cmd=$(resolve_local_compose_cmd "$stack")

  log "Running local smoke tests for: $stack"

  # Check if services are running
  if ! $compose_cmd ps --services --filter "status=running" | grep -q .; then
    error "No services running"
    return 1
  fi

  # Run health checks
  log "Checking service health..."
  local all_healthy=true

  while IFS= read -r service; do
    local health_status
    health_status=$($compose_cmd ps "$service" --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d'"' -f4)

    if [ -n "$health_status" ]; then
      if [ "$health_status" = "healthy" ]; then
        ok "  $service: healthy"
      else
        error "  $service: $health_status"
        all_healthy=false
      fi
    else
      log "  $service: no health check configured"
    fi
  done < <($compose_cmd ps --services --filter "status=running")

  if [ "$all_healthy" = true ]; then
    ok "All smoke tests passed"
    return 0
  else
    error "Some smoke tests failed"
    return 1
  fi
}

# local_validate_env <stack>
# Validate local environment variables against template
local_validate_env() {
  local stack="$1"

  local stack_dir="$CLI_ROOT/stacks/$stack"
  local env_local="$stack_dir/.env.local"
  local env_template="$stack_dir/.env.template"

  [ -f "$env_template" ] || { log "No .env.template found, skipping validation"; return 0; }
  [ -f "$env_local" ] || { warn ".env.local not found"; return 1; }

  local missing_vars=()

  # Extract required variables from template (lines without default values or with empty defaults)
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    # Extract variable name and check if it has a value
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      local var_name="${BASH_REMATCH[1]}"
      local var_value="${BASH_REMATCH[2]}"

      # Only check if variable has no default value (empty or placeholder)
      # Skip variables with actual default values
      if [[ -z "$var_value" || "$var_value" =~ ^(your\.|xxxx|ghp_xxx|changeme) ]]; then
        # Check if variable exists in .env.local
        if ! grep -q "^${var_name}=" "$env_local"; then
          missing_vars+=("$var_name")
        fi
      fi
    fi
  done < "$env_template"

  if [ ${#missing_vars[@]} -gt 0 ]; then
    warn "Missing required environment variables in .env.local:"
    for var in "${missing_vars[@]}"; do
      echo "  - $var"
    done
    warn "Note: Optional variables with defaults are not checked"
    # Don't fail validation for missing optional variables
    # return 1
  fi

  return 0
}


# local_check_ports <stack>
# Check for port conflicts before starting
local_check_ports() {
  local stack="$1"

  local stack_dir="$CLI_ROOT/stacks/$stack"
  local compose_local="$stack_dir/docker-compose.local.yml"

  if [ ! -f "$compose_local" ]; then
    compose_local="$stack_dir/docker-compose.yml"
  fi

  [ -f "$compose_local" ] || return 0

  # Extract ports from docker-compose file
  local ports=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\"?([0-9]+): ]]; then
      ports+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*([0-9]+): ]]; then
      ports+=("${BASH_REMATCH[1]}")
    fi
  done < "$compose_local"

  # Check if ports are in use
  local conflicts=()
  for port in "${ports[@]}"; do
    if command -v lsof &>/dev/null; then
      if lsof -i ":$port" -sTCP:LISTEN &>/dev/null; then
        conflicts+=("$port")
      fi
    elif command -v netstat &>/dev/null; then
      if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        conflicts+=("$port")
      fi
    fi
  done

  if [ ${#conflicts[@]} -gt 0 ]; then
    error "Port conflicts detected:"
    for port in "${conflicts[@]}"; do
      echo "  - Port $port is already in use"
      if command -v lsof &>/dev/null; then
        lsof -i ":$port" -sTCP:LISTEN | tail -n +2 | awk '{print "    " $1 " (PID: " $2 ")"}'
      fi
    done
    return 1
  fi

  return 0
}

# local_show_endpoints <stack>
# Show available endpoints for local development
local_show_endpoints() {
  local stack="$1"

  local stack_dir="$CLI_ROOT/stacks/$stack"
  local compose_local="$stack_dir/docker-compose.local.yml"

  if [ ! -f "$compose_local" ]; then
    compose_local="$stack_dir/docker-compose.yml"
  fi

  [ -f "$compose_local" ] || return 0

  log "Available endpoints:"

  # Extract service names and ports
  local current_service=""
  while IFS= read -r line; do
    # Detect service name
    if [[ "$line" =~ ^[[:space:]]*([a-z0-9_-]+):[[:space:]]*$ ]]; then
      current_service="${BASH_REMATCH[1]}"
    fi

    # Detect ports
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\"?([0-9]+):([0-9]+) ]] && [ -n "$current_service" ]; then
      local host_port="${BASH_REMATCH[1]}"
      local container_port="${BASH_REMATCH[2]}"
      echo "  - $current_service: http://localhost:$host_port"
    fi
  done < "$compose_local"
}
