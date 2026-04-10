#!/usr/bin/env bash
# ==================================================
# lib/keys/audit.sh — Key inventory and audit
# ==================================================

set -euo pipefail

# keys_inventory <stack> [--json]
keys_inventory() {
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

  if [ ! -d "$keys_dir" ]; then
    warn "No keys directory found for stack: $stack"
    return 1
  fi

  if $json_output; then
    # Combine all metadata files
    jq -n \
      --slurpfile ssh "$keys_dir/ssh-keys.json" \
      --slurpfile api "$keys_dir/api-keys.json" \
      --slurpfile github "$keys_dir/github-secrets.json" \
      --slurpfile env "$keys_dir/env-vars.json" \
      '{
        ssh_keys: $ssh[0],
        api_keys: $api[0],
        github_secrets: $github[0],
        env_vars: $env[0]
      }'
  else
    echo ""
    echo -e "${BLUE}Key Inventory for $stack${NC}"
    echo ""

    echo -e "${GREEN}SSH Keys:${NC}"
    jq -r '.ssh_keys | length' "$keys_dir/ssh-keys.json" | xargs echo "  Total:"

    echo ""
    echo -e "${GREEN}API Keys:${NC}"
    jq -r '.api_keys | length' "$keys_dir/api-keys.json" | xargs echo "  Total:"

    echo ""
    echo -e "${GREEN}GitHub Secrets:${NC}"
    jq -r '.github_secrets | length' "$keys_dir/github-secrets.json" | xargs echo "  Total repos:"

    echo ""
    echo -e "${GREEN}Environment Variables:${NC}"
    jq -r '.env_vars | length' "$keys_dir/env-vars.json" | xargs echo "  Total tracked:"

    echo ""
  fi
}

# keys_audit <stack> [--expired] [--unused]
keys_audit() {
  local stack="$1"
  shift || true

  log "Key audit - implementation pending"
  warn "This feature is not yet implemented"
}

# keys_export <stack> [--format json|csv]
keys_export() {
  local stack="$1"
  shift || true

  log "Key export - implementation pending"
  warn "This feature is not yet implemented"
}
