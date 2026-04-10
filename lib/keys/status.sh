#!/usr/bin/env bash
# ==================================================
# lib/keys/status.sh — Key status and health checks
# ==================================================

set -euo pipefail

# keys_status <stack> [--json]
# Shows health status of all keys
keys_status() {
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

  # Collect status data
  local ssh_count api_count env_count
  ssh_count=$(jq '.ssh_keys | length' "$keys_dir/ssh-keys.json" 2>/dev/null || echo 0)
  api_count=$(jq '.api_keys | length' "$keys_dir/api-keys.json" 2>/dev/null || echo 0)

  # Count environment variables
  local env_file="$CLI_ROOT/.prod.env"
  local env_count=0
  if [ -f "$env_file" ]; then
    env_count=$(grep -cE "^[A-Z_]+=" "$env_file" 2>/dev/null || echo 0)
  fi

  # Check VPS connectivity
  local vps_status="unknown"
  if [ -f "$env_file" ]; then
    set -a
    source "$env_file"
    set +a
    local vps_host="${VPS_HOST:-}"
    local vps_user="${VPS_USER:-ubuntu}"
    local vps_ssh_key="${VPS_SSH_KEY:-}"

    if [ -n "$vps_host" ]; then
      if validate_vps_connection "$vps_host" "$vps_user" "$vps_ssh_key"; then
        vps_status="connected"
      else
        vps_status="unreachable"
      fi
    fi
  fi

  # Check GitHub CLI
  local github_status="not_configured"
  if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
      github_status="authenticated"
    else
      github_status="not_authenticated"
    fi
  fi

  if $json_output; then
    jq -n \
      --arg ssh_count "$ssh_count" \
      --arg api_count "$api_count" \
      --arg env_count "$env_count" \
      --arg vps_status "$vps_status" \
      --arg github_status "$github_status" \
      --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{
        timestamp: $timestamp,
        ssh_keys: ($ssh_count | tonumber),
        api_keys: ($api_count | tonumber),
        env_vars: ($env_count | tonumber),
        vps_status: $vps_status,
        github_status: $github_status
      }'
  else
    echo ""
    echo -e "${BLUE}Key Management Status for $stack${NC}"
    echo ""

    # SSH Keys
    if [ "$ssh_count" -gt 0 ]; then
      echo -e "  ${GREEN}✓${NC} SSH Keys: $ssh_count tracked"
    else
      echo -e "  ${YELLOW}○${NC} SSH Keys: none tracked"
    fi

    # API Keys
    if [ "$api_count" -gt 0 ]; then
      echo -e "  ${GREEN}✓${NC} API Keys: $api_count tracked"
    else
      echo -e "  ${YELLOW}○${NC} API Keys: none tracked"
    fi

    # Environment Variables
    if [ "$env_count" -gt 0 ]; then
      echo -e "  ${GREEN}✓${NC} Environment: $env_count variables"
    else
      echo -e "  ${YELLOW}○${NC} Environment: no .env file"
    fi

    # VPS Status
    case "$vps_status" in
      connected)
        echo -e "  ${GREEN}✓${NC} VPS: connected"
        ;;
      unreachable)
        echo -e "  ${RED}✗${NC} VPS: unreachable"
        ;;
      *)
        echo -e "  ${YELLOW}○${NC} VPS: not configured"
        ;;
    esac

    # GitHub Status
    case "$github_status" in
      authenticated)
        echo -e "  ${GREEN}✓${NC} GitHub CLI: authenticated"
        ;;
      not_authenticated)
        echo -e "  ${YELLOW}○${NC} GitHub CLI: not authenticated (run: gh auth login)"
        ;;
      *)
        echo -e "  ${YELLOW}○${NC} GitHub CLI: not installed"
        ;;
    esac

    echo ""
  fi
}

# keys_recent <stack> [--limit <n>]
# Shows recent key operations from audit log
keys_recent() {
  local stack="$1"
  shift || true

  local limit=10
  while [[ $# -gt 0 ]]; do
    case $1 in
      --limit=*)
        limit="${1#*=}"
        shift
        ;;
      --limit)
        limit="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local audit_log="$keys_dir/key-audit.log"

  if [ ! -f "$audit_log" ]; then
    warn "No audit log found"
    return 1
  fi

  echo ""
  echo -e "${BLUE}Recent Key Operations (last $limit)${NC}"
  echo ""

  tail -n "$limit" "$audit_log" | while IFS= read -r line; do
    # Parse log line: [timestamp] user: operation - details
    if [[ "$line" =~ ^\[([^\]]+)\]\ ([^:]+):\ ([^-]+)\ -\ (.+)$ ]]; then
      local timestamp="${BASH_REMATCH[1]}"
      local user="${BASH_REMATCH[2]}"
      local operation="${BASH_REMATCH[3]}"
      local details="${BASH_REMATCH[4]}"

      # Color code by operation type
      local op_color="$NC"
      case "$operation" in
        *add* | *generate*) op_color="$GREEN" ;;
        *rotate*) op_color="$YELLOW" ;;
        *revoke* | *delete*) op_color="$RED" ;;
      esac

      # Format timestamp (show date if not today)
      local date_part="${timestamp:0:10}"
      local time_part="${timestamp:11:8}"
      local today
      today=$(date -u +"%Y-%m-%d")

      if [ "$date_part" = "$today" ]; then
        echo -e "  ${op_color}${operation}${NC} by $user at $time_part"
      else
        echo -e "  ${op_color}${operation}${NC} by $user on $date_part $time_part"
      fi
      echo "    $details"
      echo ""
    else
      echo "  $line"
    fi
  done
}
