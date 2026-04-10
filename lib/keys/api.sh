#!/usr/bin/env bash
# ==================================================
# lib/keys/api.sh — API key management
# ==================================================

set -euo pipefail

# keys_api_generate <stack> <name> [--tier standard|privileged] [--dry-run]
keys_api_generate() {
  local stack="$1"
  local name="${2:-}"
  shift 2 || true

  [ -n "$name" ] || fail "Usage: keys api:generate <name> [--tier standard|privileged] [--dry-run]"

  local tier="standard"
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --tier=*)
        tier="${1#*=}"
        shift
        ;;
      --tier)
        tier="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      *) shift ;;
    esac
  done

  # Validate tier
  if [[ "$tier" != "standard" && "$tier" != "privileged" ]]; then
    fail "Invalid tier: $tier (must be standard or privileged)"
  fi

  if $dry_run; then
    show_dry_run_changes "api:generate" "Generate new API key: $name (tier: $tier)"
    return 0
  fi

  # Check if name already exists
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/api-keys.json"

  local existing
  existing=$(jq -r --arg name "$name" '.api_keys[] | select(.name == $name) | .name' "$metadata_file" 2>/dev/null || echo "")

  if [ -n "$existing" ]; then
    warn "API key with name '$name' already exists"
    echo ""
    echo "Use a different name or rotate the existing key:"
    echo "  strut $stack keys api:rotate $name"
    echo ""
    return 1
  fi

  log "Generating API key: $name (tier: $tier)..."

  # Generate secure random key
  local api_key
  api_key=$(openssl rand -base64 32 | tr -d '=' | tr '+/' '-_')

  # Validate generated key
  if ! validate_api_key_format "$api_key"; then
    fail "Generated API key failed validation. Please try again"
  fi

  # Update metadata
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/api-keys.json"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local new_entry
  new_entry=$(jq -n \
    --arg name "$name" \
    --arg tier "$tier" \
    --arg created "$timestamp" \
    --arg key_masked "$(echo "$api_key" | head -c 8)...$(echo "$api_key" | tail -c 8)" \
    '{
      name: $name,
      tier: $tier,
      created: $created,
      rotated: $created,
      expires: null,
      last_used: null,
      key_masked: $key_masked
    }')

  # Add to metadata
  local updated_metadata
  updated_metadata=$(jq \
    --argjson entry "$new_entry" \
    --arg name "$name" \
    --arg ts "$timestamp" \
    '.api_keys = (.api_keys | map(select(.name != $name))) + [$entry] | .last_updated = $ts' \
    "$metadata_file")

  echo "$updated_metadata" >"$metadata_file"

  log_key_operation "$stack" "api:generate" "Generated API key: $name (tier: $tier)"

  echo ""
  ok "API key generated: $name"
  echo ""
  echo -e "${YELLOW}IMPORTANT: Save this key securely - it won't be shown again!${NC}"
  echo ""
  echo "API Key: $api_key"
  echo ""
  echo "Add to your .env file:"
  if [ "$tier" = "privileged" ]; then
    echo "  SEMANTIC_API_KEYS_PRIVILEGED=$api_key"
  else
    echo "  SEMANTIC_API_KEYS=$api_key"
  fi
  echo ""
}

# keys_api_rotate <stack> <name> [--dry-run]
keys_api_rotate() {
  local stack="$1"
  local name="${2:-}"
  shift 2 || true

  [ -n "$name" ] || fail "Usage: keys api:rotate <name> [--dry-run]"

  local dry_run=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run)
        dry_run=true
        shift
        ;;
      *) shift ;;
    esac
  done

  # Get current tier from metadata
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/api-keys.json"

  local tier
  tier=$(jq -r --arg name "$name" '.api_keys[] | select(.name == $name) | .tier' "$metadata_file")

  if [ -z "$tier" ] || [ "$tier" = "null" ]; then
    fail "API key not found: $name"
  fi

  if $dry_run; then
    show_dry_run_changes "api:rotate" "Rotate API key: $name (tier: $tier) - old key will be invalidated"
    return 0
  fi

  echo ""
  warn "This will invalidate the old API key for: $name"
  echo ""
  echo "You will need to:"
  echo "  1. Update .env file with new key"
  echo "  2. Restart services: strut $stack deploy --env prod"
  echo ""
  confirm "Continue?" || {
    log "Cancelled"
    return 1
  }

  # Generate new key
  keys_api_generate "$stack" "$name" --tier "$tier"
}

# keys_api_revoke <stack> <name> [--dry-run] [--force]
keys_api_revoke() {
  local stack="$1"
  local name="${2:-}"
  shift 2 || true

  [ -n "$name" ] || fail "Usage: keys api:revoke <name> [--dry-run] [--force]"

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

  # Check if key exists
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/api-keys.json"

  local existing
  existing=$(jq -r --arg name "$name" '.api_keys[] | select(.name == $name) | .name' "$metadata_file" 2>/dev/null || echo "")

  if [ -z "$existing" ]; then
    warn "API key not found: $name"
    return 1
  fi

  if $dry_run; then
    show_dry_run_changes "api:revoke" "Revoke API key: $name (will be permanently deleted)"
    return 0
  fi

  echo ""
  warn "This will permanently revoke the API key: $name"
  echo ""
  echo "Remember to:"
  echo "  1. Remove from .env file"
  echo "  2. Restart services: strut $stack deploy --env prod"
  echo ""

  if ! $force; then
    confirm "Continue?" || {
      log "Cancelled"
      return 1
    }
  fi

  # Remove from metadata
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/api-keys.json"

  local updated_metadata
  updated_metadata=$(jq \
    --arg name "$name" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.api_keys = (.api_keys | map(select(.name != $name))) | .last_updated = $ts' \
    "$metadata_file")

  echo "$updated_metadata" >"$metadata_file"

  log_key_operation "$stack" "api:revoke" "Revoked API key: $name"

  ok "API key revoked: $name"
  echo ""
  echo "Remember to remove from .env file and restart services"
  echo ""
}

# keys_api_list <stack> [--json]
keys_api_list() {
  local stack="$1"
  shift || true

  local json_output=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json)
        json_output=true
        shift
        ;;
      *) shift ;;
    esac
  done

  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/api-keys.json"

  if $json_output; then
    jq '.api_keys' "$metadata_file"
  else
    echo ""
    echo -e "${BLUE}API Keys for $stack${NC}"
    echo ""

    local count
    count=$(jq '.api_keys | length' "$metadata_file")

    if [ "$count" -eq 0 ]; then
      echo "  No API keys tracked"
    else
      jq -r '.api_keys[] | "  \(.name) (\(.tier))\n    Key: \(.key_masked)\n    Created: \(.created)\n    Last rotated: \(.rotated)\n"' "$metadata_file"
    fi

    echo ""
  fi
}

# keys_api_test <stack> <name>
keys_api_test() {
  local stack="$1"
  local name="${2:-}"

  [ -n "$name" ] || fail "Usage: keys api:test <name>"

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
