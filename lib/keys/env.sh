#!/usr/bin/env bash
# ==================================================
# lib/keys/env.sh — Environment variable management
# ==================================================

set -euo pipefail

# keys_env_rotate <stack> [--services <list>] [--dry-run] [--force]
keys_env_rotate() {
  local stack="$1"
  shift || true

  local services=""
  local dry_run=false
  local force=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --services=*)
        services="${1#*=}"
        shift
        ;;
      --services)
        services="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --force)
        force=true
        shift
        ;;
      *) shift ;;
    esac
  done

  echo ""
  warn "Environment variable rotation is a complex operation"
  echo ""
  echo "This will rotate the following secrets:"
  echo "  - NEO4J_PASSWORD"
  echo "  - POSTGRES_PASSWORD"
  echo "  - API_SECRET_KEY"
  echo "  - MISTRAL_API_KEY (manual - requires new key from Mistral)"
  echo ""
  echo "After rotation, you MUST:"
  echo "  1. Update database passwords: strut $stack keys db:rotate postgres"
  echo "  2. Redeploy services: strut $stack deploy --env prod"
  echo ""

  if $dry_run; then
    show_dry_run_changes "env:rotate" "Rotate NEO4J_PASSWORD, POSTGRES_PASSWORD, API_SECRET_KEY"
    return 0
  fi

  if ! $force; then
    confirm "Continue with rotation?" || {
      log "Cancelled"
      return 1
    }
  fi

  local env_file="$CLI_ROOT/.prod.env"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"

  # Backup current env
  local backup_file="$env_file.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$env_file" "$backup_file"
  ok "Backed up to: $backup_file"

  # Generate new secrets
  log "Generating new secrets..."

  local new_neo4j_password
  new_neo4j_password=$(openssl rand -base64 32)

  local new_postgres_password
  new_postgres_password=$(openssl rand -base64 32)

  local new_api_secret
  new_api_secret=$(openssl rand -hex 32)

  # Update env file
  log "Updating .env file..."

  sed -i.tmp "s|^NEO4J_PASSWORD=.*|NEO4J_PASSWORD=$new_neo4j_password|" "$env_file"
  sed -i.tmp "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$new_postgres_password|" "$env_file"
  sed -i.tmp "s|^API_SECRET_KEY=.*|API_SECRET_KEY=$new_api_secret|" "$env_file"
  rm -f "$env_file.tmp"

  ok "Environment file updated"

  # Update metadata
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/env-vars.json"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local updated_metadata
  updated_metadata=$(jq \
    --arg ts "$timestamp" \
    '.env_vars.NEO4J_PASSWORD = {last_rotated: $ts, expires: null, synced_to_github: false} |
     .env_vars.POSTGRES_PASSWORD = {last_rotated: $ts, expires: null, synced_to_github: false} |
     .env_vars.API_SECRET_KEY = {last_rotated: $ts, expires: null, synced_to_github: false} |
     .last_updated = $ts' \
    "$metadata_file")

  echo "$updated_metadata" >"$metadata_file"

  log_key_operation "$stack" "env:rotate" "Rotated NEO4J_PASSWORD, POSTGRES_PASSWORD, API_SECRET_KEY"

  echo ""
  warn "IMPORTANT: You must now update the running services with new credentials:"
  echo ""
  echo "1. Update Neo4j password:"
  echo "   strut $stack keys db:rotate neo4j"
  echo ""
  echo "2. Update Postgres password:"
  echo "   strut $stack keys db:rotate postgres"
  echo ""
  echo "3. Redeploy services to pick up new API_SECRET_KEY:"
  echo "   strut $stack deploy --env prod"
  echo ""
  echo "Backup saved to: $backup_file"
  echo ""
}

# keys_env_set <stack> <key> <value> [--encrypt] [--dry-run]
keys_env_set() {
  local stack="$1"
  local key="${2:-}"
  local value="${3:-}"
  shift 3 || true

  [ -n "$key" ] || fail "Usage: keys env:set <key> <value> [--encrypt] [--dry-run]"
  [ -n "$value" ] || fail "Usage: keys env:set <key> <value> [--encrypt] [--dry-run]"

  # Validate key format (should be uppercase with underscores)
  if ! [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    fail "Invalid key format: $key (must be uppercase with underscores, e.g., MY_SECRET_KEY)"
  fi

  local encrypt=false
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --encrypt)
        encrypt=true
        shift
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      *) shift ;;
    esac
  done

  local env_file="$CLI_ROOT/.prod.env"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"

  # Check if key exists
  local action="Adding"
  if grep -q "^${key}=" "$env_file"; then
    action="Updating"
  fi

  if $dry_run; then
    show_dry_run_changes "env:set" "$action environment variable: $key"
    return 0
  fi

  # Backup
  cp "$env_file" "$env_file.backup-$(date +%Y%m%d-%H%M%S)"

  # Check if key exists
  if grep -q "^${key}=" "$env_file"; then
    log "Updating existing key: $key"
    sed -i.tmp "s|^${key}=.*|${key}=${value}|" "$env_file"
    rm -f "$env_file.tmp"
  else
    log "Adding new key: $key"
    echo "${key}=${value}" >>"$env_file"
  fi

  ok "Environment variable set: $key"

  log_key_operation "$stack" "env:set" "Set $key"
}

# keys_env_sync <stack>
keys_env_sync() {
  local stack="$1"

  local env_file="$CLI_ROOT/.prod.env"
  local template_file="$CLI_ROOT/stacks/$stack/.env.template"

  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  [ -f "$template_file" ] || fail "Template file not found: $template_file"

  log "Syncing .env from template..."

  # Get keys from template
  local template_keys
  template_keys=$(grep -E "^[A-Z_]+=" "$template_file" | cut -d= -f1 | sort)

  # Get keys from env
  local env_keys
  env_keys=$(grep -E "^[A-Z_]+=" "$env_file" | cut -d= -f1 | sort)

  # Find missing keys
  local missing_keys
  missing_keys=$(comm -23 <(echo "$template_keys") <(echo "$env_keys"))

  if [ -z "$missing_keys" ]; then
    ok "All template keys present in .env"
    return 0
  fi

  echo ""
  warn "Missing keys in .env:"
  echo "$missing_keys" | while read -r key; do
    echo "  - $key"
  done
  echo ""

  confirm "Add missing keys to .env?" || {
    log "Cancelled"
    return 1
  }

  # Backup
  cp "$env_file" "$env_file.backup-$(date +%Y%m%d-%H%M%S)"

  # Add missing keys
  echo "$missing_keys" | while read -r key; do
    local template_value
    template_value=$(grep "^${key}=" "$template_file" | cut -d= -f2-)
    echo "${key}=${template_value}" >>"$env_file"
    log "Added: $key"
  done

  ok "Environment file synced"

  log_key_operation "$stack" "env:sync" "Synced $(echo "$missing_keys" | wc -l | xargs) keys from template"
}

# keys_env_validate <stack>
keys_env_validate() {
  local stack="$1"

  local env_file="$CLI_ROOT/.prod.env"
  local template_file="$CLI_ROOT/stacks/$stack/.env.template"

  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  [ -f "$template_file" ] || fail "Template file not found: $template_file"

  log "Validating .env completeness..."

  # Get required keys from template (non-commented, non-empty)
  local template_keys
  template_keys=$(grep -E "^[A-Z_]+=" "$template_file" | cut -d= -f1 | sort)

  # Get keys from env
  local env_keys
  env_keys=$(grep -E "^[A-Z_]+=" "$env_file" | cut -d= -f1 | sort)

  # Find missing keys
  local missing_keys
  missing_keys=$(comm -23 <(echo "$template_keys") <(echo "$env_keys"))

  # Find empty values
  local empty_values
  empty_values=$(grep -E "^[A-Z_]+=\s*$" "$env_file" | cut -d= -f1 || echo "")

  echo ""
  echo -e "${BLUE}Environment Validation for $stack${NC}"
  echo ""

  local issues=0

  if [ -n "$missing_keys" ]; then
    warn "Missing keys:"
    echo "$missing_keys" | while read -r key; do
      echo "  - $key"
    done
    echo ""
    ((issues++)) || true # arithmetic returns 1 when result is 0
  fi

  if [ -n "$empty_values" ]; then
    warn "Empty values:"
    echo "$empty_values" | while read -r key; do
      echo "  - $key"
    done
    echo ""
    ((issues++)) || true # arithmetic returns 1 when result is 0
  fi

  if [ "$issues" -eq 0 ]; then
    ok "Environment file is valid"
  else
    warn "Found $issues validation issues"
    echo "Run: strut $stack keys env:sync"
  fi

  echo ""
}

# keys_env_backup <stack> [--encrypt]
keys_env_backup() {
  local stack="$1"
  shift || true

  local encrypt=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --encrypt)
        encrypt=true
        shift
        ;;
      *) shift ;;
    esac
  done

  local env_file="$CLI_ROOT/.prod.env"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"

  local backup_dir="$CLI_ROOT/stacks/$stack/keys"
  mkdir -p "$backup_dir"

  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local backup_file="$backup_dir/env-backup-$timestamp"

  if $encrypt; then
    # Check if age is available
    if command -v age &>/dev/null; then
      log "Creating encrypted backup..."
      age -p -o "$backup_file.age" "$env_file"
      ok "Encrypted backup created: $backup_file.age"
    else
      warn "age not installed - creating unencrypted backup"
      warn "Install age: brew install age"
      cp "$env_file" "$backup_file"
      ok "Backup created: $backup_file"
    fi
  else
    log "Creating backup..."
    cp "$env_file" "$backup_file"
    ok "Backup created: $backup_file"
  fi

  log_key_operation "$stack" "env:backup" "Created backup: $(basename "$backup_file")"
}

# keys_env_diff <stack> --local <file> --remote
keys_env_diff() {
  local stack="$1"
  shift || true

  local local_file=""
  local compare_remote=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --local=*)
        local_file="${1#*=}"
        shift
        ;;
      --local)
        local_file="$2"
        shift 2
        ;;
      --remote)
        compare_remote=true
        shift
        ;;
      *) shift ;;
    esac
  done

  [ -n "$local_file" ] || fail "Usage: keys env:diff --local <file> --remote"
  [ -f "$local_file" ] || fail "Local file not found: $local_file"

  if ! $compare_remote; then
    fail "Usage: keys env:diff --local <file> --remote"
  fi

  # Load VPS connection info
  local env_file="$CLI_ROOT/.prod.env"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a
  source "$env_file"
  set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_deploy_dir="${VPS_DEPLOY_DIR:-/home/${vps_user}/strut}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -k "$vps_ssh_key" --batch)

  log "Comparing local .env with VPS..."

  # Get remote env file
  local remote_env="/tmp/remote-env-$$"
  scp $ssh_opts "$vps_user@$vps_host:$vps_deploy_dir/.prod.env" "$remote_env" 2>/dev/null || {
    warn "Could not fetch remote .env file"
    return 1
  }

  # Compare
  echo ""
  echo -e "${BLUE}Environment Diff${NC}"
  echo ""

  diff -u "$remote_env" "$local_file" || true # diff returns 1 when files differ — expected

  rm -f "$remote_env"

  echo ""
}
