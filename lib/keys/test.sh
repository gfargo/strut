#!/usr/bin/env bash
# ==================================================
# lib/keys/test.sh — Key testing and verification
# ==================================================

set -euo pipefail

# keys_test_all <stack>
# Tests all keys to verify they work
keys_test_all() {
  local stack="$1"

  echo ""
  echo -e "${BLUE}Testing All Keys for $stack${NC}"
  echo ""

  local total=0
  local passed=0
  local failed=0

  # Test SSH keys
  log "Testing SSH keys..."
  if keys_test_ssh_all "$stack"; then
    ((passed++)) || true
  else
    ((failed++)) || true
  fi
  ((total++)) || true

  # Test VPS connectivity
  log "Testing VPS connectivity..."
  if keys_test_vps "$stack"; then
    ((passed++)) || true
  else
    ((failed++)) || true
  fi
  ((total++)) || true

  # Test environment variables
  log "Testing environment configuration..."
  if keys_test_env "$stack"; then
    ((passed++)) || true
  else
    ((failed++)) || true
  fi
  ((total++)) || true

  echo ""
  echo -e "${BLUE}Test Summary${NC}"
  echo "  Total: $total"
  echo -e "  ${GREEN}Passed: $passed${NC}"
  if [ "$failed" -gt 0 ]; then
    echo -e "  ${RED}Failed: $failed${NC}"
  fi
  echo ""

  [ "$failed" -eq 0 ]
}

# keys_test_ssh_all <stack>
# Tests all SSH keys
keys_test_ssh_all() {
  local stack="$1"
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/ssh-keys.json"

  local key_count
  key_count=$(jq '.ssh_keys | length' "$metadata_file" 2>/dev/null || echo 0)

  if [ "$key_count" -eq 0 ]; then
    warn "No SSH keys to test"
    return 0
  fi

  # Load VPS connection info
  local env_file="$CLI_ROOT/.prod.env"
  if [ ! -f "$env_file" ]; then
    error "Env file not found: $env_file"
    return 1
  fi

  set -a
  source "$env_file"
  set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"

  if [ -z "$vps_host" ]; then
    error "VPS_HOST not set in $env_file"
    return 1
  fi

  local all_passed=true

  # Test each key
  jq -r '.ssh_keys[] | "\(.username)|\(.key_file)"' "$metadata_file" | while IFS='|' read -r username key_file; do
    local private_key="${key_file%.pub}"

    if [ ! -f "$private_key" ]; then
      echo -e "  ${YELLOW}○${NC} $username: private key not found ($private_key)"
      continue
    fi

    if ssh -n -i "$private_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
      "$vps_user@$vps_host" "echo 'ok'" &>/dev/null; then
      echo -e "  ${GREEN}✓${NC} $username: SSH connection successful"
    else
      echo -e "  ${RED}✗${NC} $username: SSH connection failed"
      all_passed=false
    fi
  done

  $all_passed
}

# keys_test_vps <stack>
# Tests VPS connectivity
keys_test_vps() {
  local stack="$1"
  local env_file="$CLI_ROOT/.prod.env"

  if [ ! -f "$env_file" ]; then
    error "Env file not found: $env_file"
    return 1
  fi

  set -a
  source "$env_file"
  set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"

  if [ -z "$vps_host" ]; then
    error "VPS_HOST not set"
    return 1
  fi

  if validate_vps_connection "$vps_host" "$vps_user" "$vps_ssh_key"; then
    ok "VPS connection successful ($vps_host)"
    return 0
  else
    error "VPS connection failed ($vps_host)"
    return 1
  fi
}

# keys_test_env <stack>
# Tests environment configuration
keys_test_env() {
  local stack="$1"
  local env_file="$CLI_ROOT/.prod.env"
  local template_file="$CLI_ROOT/stacks/$stack/.env.template"

  if [ ! -f "$env_file" ]; then
    error "Env file not found: $env_file"
    return 1
  fi

  if [ ! -f "$template_file" ]; then
    warn "Template file not found: $template_file"
    return 0
  fi

  # Get required keys from template
  local template_keys
  template_keys=$(grep -E "^[A-Z_]+=" "$template_file" | cut -d= -f1 | sort)

  # Get keys from env
  local env_keys
  env_keys=$(grep -E "^[A-Z_]+=" "$env_file" | cut -d= -f1 | sort)

  # Find missing keys
  local missing_keys
  missing_keys=$(comm -23 <(echo "$template_keys") <(echo "$env_keys"))

  # Find empty values
  local empty_count
  empty_count=$(grep -cE "^[A-Z_]+=\s*$" "$env_file" 2>/dev/null || echo 0)

  if [ -z "$missing_keys" ] && [ "$empty_count" -eq 0 ]; then
    ok "Environment configuration valid"
    return 0
  else
    if [ -n "$missing_keys" ]; then
      error "Missing keys: $(echo "$missing_keys" | wc -l | xargs)"
    fi
    if [ "$empty_count" -gt 0 ]; then
      error "Empty values: $empty_count"
    fi
    return 1
  fi
}

# keys_test_api <stack> <name>
# Tests a specific API key against endpoints
keys_test_api() {
  local stack="$1"
  local name="${2:-}"

  [ -n "$name" ] || fail "Usage: keys test:api <name>"

  warn "API key testing requires the actual key value"
  echo ""
  echo "To test an API key:"
  echo ""
  echo "1. Get the API key from your .env file"
  echo "2. Test with curl:"
  echo ""
  echo "   curl -H \"Authorization: Bearer YOUR_API_KEY\" \\"
  echo "     http://localhost:8000/api/v1/health"
  echo ""
  echo "3. Check for 200 OK response"
  echo ""
}

# keys_test_db <stack> <postgres|neo4j>
# Tests database connection
keys_test_db() {
  local stack="$1"
  local db_type="${2:-}"

  [ -n "$db_type" ] || fail "Usage: keys test:db <postgres|neo4j>"

  local env_file="$CLI_ROOT/.prod.env"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a
  source "$env_file"
  set +a

  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "")

  case "$db_type" in
    postgres)
      local postgres_user="${POSTGRES_USER:-postgres}"
      local postgres_db="${POSTGRES_DB:-app_db}"

      log "Testing PostgreSQL connection..."

      if $compose_cmd exec -T postgres psql -U "$postgres_user" -d "$postgres_db" -c "SELECT 1;" &>/dev/null; then
        ok "PostgreSQL connection successful"
        return 0
      else
        error "PostgreSQL connection failed"
        return 1
      fi
      ;;

    neo4j)
      warn "Neo4j connection testing requires manual verification"
      echo ""
      echo "To test Neo4j connection:"
      echo "  1. Check if Neo4j is running: docker compose ps neo4j"
      echo "  2. Try connecting with cypher-shell or Neo4j Browser"
      echo ""
      return 0
      ;;

    *)
      fail "Unknown database type: $db_type (postgres|neo4j)"
      ;;
  esac
}

# keys_test_github <stack>
# Tests GitHub CLI authentication and access
keys_test_github() {
  local stack="$1"

  if ! command -v gh &>/dev/null; then
    error "GitHub CLI (gh) not installed"
    return 1
  fi

  log "Testing GitHub CLI authentication..."

  if gh auth status &>/dev/null; then
    ok "GitHub CLI authenticated"

    # Test access to a repo
    # Test access to a repo using DEFAULT_ORG
    local test_repo="${DEFAULT_ORG:-}/strut"
    if [ -z "${DEFAULT_ORG:-}" ]; then
      warn "DEFAULT_ORG not set — skipping repository access test"
      return 0
    fi
    log "Testing repository access..."
    if gh repo view "$test_repo" &>/dev/null; then
      ok "Repository access successful"
      return 0
    else
      warn "Repository access failed (may need additional permissions)"
      return 1
    fi
  else
    error "GitHub CLI not authenticated (run: gh auth login)"
    return 1
  fi
}
