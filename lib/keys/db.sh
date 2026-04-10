#!/usr/bin/env bash
# ==================================================
# lib/keys/db.sh — Database credential management
# ==================================================

set -euo pipefail

# keys_db_rotate <stack> <neo4j|postgres>
keys_db_rotate() {
  local stack="$1"
  local db_type="${2:-}"

  [ -n "$db_type" ] || fail "Usage: keys db:rotate <neo4j|postgres>"

  case "$db_type" in
    neo4j)
      keys_db_rotate_neo4j "$stack"
      ;;
    postgres)
      keys_db_rotate_postgres "$stack"
      ;;
    *)
      fail "Unknown database type: $db_type (neo4j|postgres)"
      ;;
  esac
}

# keys_db_rotate_neo4j <stack>
keys_db_rotate_neo4j() {
  local stack="$1"

  warn "Neo4j password rotation requires manual steps"
  echo ""
  echo "For Neo4j Aura (managed):"
  echo "  1. Go to Neo4j Aura console"
  echo "  2. Reset password for your database"
  echo "  3. Update .env file: NEO4J_PASSWORD=<new-password>"
  echo "  4. Redeploy services: strut $stack deploy --env prod"
  echo ""
  echo "For self-hosted Neo4j:"
  echo "  1. Connect to Neo4j with current password"
  echo "  2. Run: ALTER CURRENT USER SET PASSWORD FROM 'old' TO 'new'"
  echo "  3. Update .env file: NEO4J_PASSWORD=<new-password>"
  echo "  4. Redeploy services: strut $stack deploy --env prod"
  echo ""

  log_key_operation "$stack" "db:rotate" "Neo4j password rotation initiated (manual)"
}

# keys_db_rotate_postgres <stack> [--dry-run] [--force]
keys_db_rotate_postgres() {
  local stack="$1"
  shift || true

  local dry_run=false
  local force=false

  while [[ $# -gt 0 ]]; do
    case $1 in
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

  log "Rotating PostgreSQL password..."

  # Load env
  local env_file="$CLI_ROOT/.prod.env"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a
  source "$env_file"
  set +a

  local postgres_user="${POSTGRES_USER:-postgres}"
  local postgres_db="${POSTGRES_DB:-app_db}"
  local old_password="${POSTGRES_PASSWORD:-}"

  [ -n "$old_password" ] || fail "POSTGRES_PASSWORD not set in $env_file"

  # Generate new password
  local new_password
  new_password=$(openssl rand -base64 32)

  if $dry_run; then
    show_dry_run_changes "db:rotate" "Rotate PostgreSQL password for user: $postgres_user"
    echo "  This will:"
    echo "    1. Update password in database"
    echo "    2. Update .env file"
    echo "    3. Create backup of old .env"
    echo ""
    return 0
  fi

  echo ""
  warn "This will change the PostgreSQL password for user: $postgres_user"
  echo ""
  echo "After rotation, you MUST restart services:"
  echo "  strut $stack deploy --env prod"
  echo ""

  if ! $force; then
    confirm "Continue?" || {
      log "Cancelled"
      return 1
    }
  fi

  # Get compose command
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "")

  # Check if postgres is running
  if ! $compose_cmd ps postgres 2>/dev/null | grep -q "Up"; then
    fail "PostgreSQL container is not running. Start services first: strut $stack deploy --env prod"
  fi

  log "Updating PostgreSQL password..."

  # Update password in database
  $compose_cmd exec -T postgres psql -U "$postgres_user" -d "$postgres_db" <<EOF
ALTER USER $postgres_user WITH PASSWORD '$new_password';
EOF

  ok "PostgreSQL password updated in database"

  # Update .env file
  local backup_file="$env_file.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$env_file" "$backup_file"

  sed -i.tmp "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$new_password|" "$env_file"
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
    '.env_vars.POSTGRES_PASSWORD = {last_rotated: $ts, expires: null, synced_to_github: false} |
     .last_updated = $ts' \
    "$metadata_file")

  echo "$updated_metadata" >"$metadata_file"

  log_key_operation "$stack" "db:rotate" "Rotated PostgreSQL password"

  echo ""
  ok "PostgreSQL password rotated successfully"
  echo ""
  echo "Next steps:"
  echo "  1. Restart services to pick up new password:"
  echo "     strut $stack deploy --env prod"
  echo ""
  echo "Backup saved to: $backup_file"
  echo ""
}

# keys_db_create_readonly <stack> <username>
keys_db_create_readonly() {
  local stack="$1"
  local username="${2:-}"

  [ -n "$username" ] || fail "Usage: keys db:create-readonly <username>"

  log "Creating read-only database user: $username..."

  # Load env
  local env_file="$CLI_ROOT/.prod.env"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a
  source "$env_file"
  set +a

  local postgres_user="${POSTGRES_USER:-postgres}"
  local postgres_db="${POSTGRES_DB:-app_db}"

  # Generate password
  local password
  password=$(openssl rand -base64 24)

  # Get compose command
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "")

  log "Creating PostgreSQL read-only user..."

  # Create user and grant permissions
  $compose_cmd exec -T postgres psql -U "$postgres_user" -d "$postgres_db" <<EOF
-- Create user
CREATE USER $username WITH PASSWORD '$password';

-- Grant connect
GRANT CONNECT ON DATABASE $postgres_db TO $username;

-- Grant usage on schema
GRANT USAGE ON SCHEMA public TO $username;

-- Grant select on all tables
GRANT SELECT ON ALL TABLES IN SCHEMA public TO $username;

-- Grant select on future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO $username;
EOF

  ok "PostgreSQL read-only user created"

  # For Neo4j
  log "Creating Neo4j read-only user..."

  local neo4j_uri="${NEO4J_URI:-}"
  local neo4j_user="${NEO4J_USER:-neo4j}"
  local neo4j_password="${NEO4J_PASSWORD:-}"

  if [ -n "$neo4j_uri" ] && [ -n "$neo4j_password" ]; then
    # Generate Neo4j password
    local neo4j_ro_password
    neo4j_ro_password=$(openssl rand -base64 24)

    warn "Neo4j read-only user creation requires manual steps:"
    echo ""
    echo "1. Connect to Neo4j Browser"
    echo "2. Run these commands:"
    echo ""
    echo "   CREATE USER $username SET PASSWORD '$neo4j_ro_password' CHANGE NOT REQUIRED;"
    echo "   GRANT ROLE reader TO $username;"
    echo ""
  fi

  echo ""
  ok "Read-only user created: $username"
  echo ""
  echo -e "${YELLOW}IMPORTANT: Save these credentials securely!${NC}"
  echo ""
  echo "PostgreSQL:"
  echo "  Host: postgres (or VPS_HOST for external)"
  echo "  Port: 5432"
  echo "  Database: $postgres_db"
  echo "  User: $username"
  echo "  Password: $password"
  echo ""
  echo "Connection string:"
  echo "  postgresql://$username:$password@postgres:5432/$postgres_db"
  echo ""

  log_key_operation "$stack" "db:create-readonly" "Created read-only user: $username"
}
