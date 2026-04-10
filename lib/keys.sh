#!/usr/bin/env bash
# ==================================================
# lib/keys.sh — Key management orchestration
# ==================================================
# Main entry point for key management commands.
# Delegates to specialized modules in lib/keys/

set -euo pipefail

# Source utilities
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/utils.sh"

# Source key management modules
source "$LIB_DIR/keys/discovery.sh"
source "$LIB_DIR/keys/ssh.sh"
source "$LIB_DIR/keys/api.sh"
source "$LIB_DIR/keys/env.sh"
source "$LIB_DIR/keys/db.sh"
source "$LIB_DIR/keys/github.sh"
source "$LIB_DIR/keys/audit.sh"
source "$LIB_DIR/keys/status.sh"
source "$LIB_DIR/keys/test.sh"
source "$LIB_DIR/keys/pull.sh"

# ── Validation & Safety Helpers ──────────────────────────────────────────────

# validate_vps_connection <vps_host> <vps_user> <vps_ssh_key> [vps_port] [timeout]
# Returns 0 if VPS is reachable, 1 otherwise
validate_vps_connection() {
  local vps_host="$1"
  local vps_user="$2"
  local vps_ssh_key="$3"
  local vps_port="${4:-22}"
  local timeout="${5:-5}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" -t "$timeout" --batch --keepalive)

  # Try connection with timeout
  if timeout "$timeout" ssh $ssh_opts "$vps_user@$vps_host" "echo 'ok'" &>/dev/null; then
    return 0
  else
    local exit_code=$?
    # Distinguish between timeout and other errors
    if [ $exit_code -eq 124 ]; then
      error "VPS connection timed out after ${timeout}s"
    fi
    return 1
  fi
}

# validate_ssh_key_format <key_file>
# Returns 0 if key file is valid SSH public key format
validate_ssh_key_format() {
  local key_file="$1"

  [ -f "$key_file" ] || return 1  # silent check — caller handles messaging

  # Check if it starts with ssh-rsa, ssh-ed25519, etc.
  if grep -qE "^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp)" "$key_file"; then
    return 0
  else
    return 1
  fi
}

# validate_api_key_format <api_key>
# Returns 0 if API key looks valid (base64-like, reasonable length)
validate_api_key_format() {
  local api_key="$1"
  local length=${#api_key}

  # Should be at least 32 chars and contain base64-like characters
  if [ "$length" -ge 32 ] && [[ "$api_key" =~ ^[A-Za-z0-9_-]+$ ]]; then
    return 0
  else
    return 1
  fi
}

# check_last_admin_key <stack> <username>
# Returns 0 if this is NOT the last admin key, 1 if it is
check_last_admin_key() {
  local stack="$1"
  local username="$2"
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/ssh-keys.json"

  local key_count
  key_count=$(jq '.ssh_keys | length' "$metadata_file" 2>/dev/null || echo 0)

  # If only 1 key and it's this user, it's the last admin key
  if [ "$key_count" -eq 1 ]; then
    local existing_user
    existing_user=$(jq -r '.ssh_keys[0].username' "$metadata_file" 2>/dev/null || echo "")
    if [ "$existing_user" = "$username" ]; then
      return 1  # This IS the last admin key
    fi
  fi

  return 0  # Not the last admin key
}

# get_stack_repos <stack>
# Returns array of repos for a stack from repos.conf or defaults
# Outputs one repo per line to stdout
get_stack_repos() {
  local stack="$1"
  local repos_conf="$CLI_ROOT/stacks/$stack/repos.conf"

  if [ -f "$repos_conf" ]; then
    # Read from config file, skip comments and empty lines
    grep -v "^#" "$repos_conf" | grep -v "^[[:space:]]*$" || true  # empty config is valid
  elif [ -n "${DEFAULT_ORG:-}" ]; then
    warn "No repos.conf found for stack '$stack' — DEFAULT_ORG is set to '$DEFAULT_ORG' but no repos are configured"
    warn "Create stacks/$stack/repos.conf with one repo per line (e.g., $DEFAULT_ORG/my-repo)"
  else
    warn "No repos.conf found for stack '$stack' and DEFAULT_ORG is not set — no repos available"
  fi
}

# show_dry_run_changes <operation> <details>
# Shows what would be changed in dry-run mode
show_dry_run_changes() {
  local operation="$1"
  local details="$2"

  echo ""
  echo -e "${BLUE}[DRY RUN] Would perform:${NC}"
  echo "  Operation: $operation"
  echo "  Details: $details"
  echo ""
}

# ── Key metadata directory ────────────────────────────────────────────────────

# get_keys_dir <stack>
# Returns the path to the keys metadata directory for a stack
get_keys_dir() {
  local stack="$1"
  echo "$CLI_ROOT/stacks/$stack/keys"
}

# ensure_keys_dir <stack>
# Creates the keys metadata directory if it doesn't exist
ensure_keys_dir() {
  local stack="$1"
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")

  if [ ! -d "$keys_dir" ]; then
    log "Creating keys metadata directory: $keys_dir"
    mkdir -p "$keys_dir"

    # Create initial metadata files
    local _ts
    _ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "{\"ssh_keys\": [], \"last_updated\": \"${_ts}\"}" > "$keys_dir/ssh-keys.json"
    echo "{\"api_keys\": [], \"last_updated\": \"${_ts}\"}" > "$keys_dir/api-keys.json"
    echo "{\"github_secrets\": [], \"last_updated\": \"${_ts}\"}" > "$keys_dir/github-secrets.json"
    echo "{\"env_vars\": {}, \"last_updated\": \"${_ts}\"}" > "$keys_dir/env-vars.json"
    touch "$keys_dir/key-audit.log"

    # Add .gitignore to prevent accidental secret commits
    cat > "$keys_dir/.gitignore" <<'EOF'
# Never commit actual secrets
*.key
*.pem
*.env
*.encrypted
*-backup-*

# Metadata files are OK to commit
!*.json
!key-audit.log
EOF

    ok "Keys metadata directory initialized"
  else
    # Verify .gitignore exists
    if [ ! -f "$keys_dir/.gitignore" ]; then
      warn "Missing .gitignore in keys directory - creating it"
      cat > "$keys_dir/.gitignore" <<'EOF'
# Never commit actual secrets
*.key
*.pem
*.env
*.encrypted
*-backup-*

# Metadata files are OK to commit
!*.json
!key-audit.log
EOF
    fi

    # Verify and repair metadata files
    for file in ssh-keys.json api-keys.json github-secrets.json env-vars.json; do
      local filepath="$keys_dir/$file"

      if [ ! -f "$filepath" ]; then
        warn "Missing metadata file: $file - creating it"
        local _rts
        _rts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        case "$file" in
          ssh-keys.json|api-keys.json|github-secrets.json)
            echo "{\"${file%-keys.json}_keys\": [], \"last_updated\": \"${_rts}\"}" > "$filepath"
            ;;
          env-vars.json)
            echo "{\"env_vars\": {}, \"last_updated\": \"${_rts}\"}" > "$filepath"
            ;;
        esac
      elif ! jq empty "$filepath" 2>/dev/null; then
        error "Corrupted JSON in $file - backing up and recreating"
        mv "$filepath" "$filepath.corrupted.$(date +%Y%m%d-%H%M%S)"
        local _rts2
        _rts2="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        case "$file" in
          ssh-keys.json|api-keys.json|github-secrets.json)
            echo "{\"${file%-keys.json}_keys\": [], \"last_updated\": \"${_rts2}\"}" > "$filepath"
            ;;
          env-vars.json)
            echo "{\"env_vars\": {}, \"last_updated\": \"${_rts2}\"}" > "$filepath"
            ;;
        esac
        warn "Corrupted file backed up to: $filepath.corrupted.*"
      fi
    done

    # Ensure audit log exists
    if [ ! -f "$keys_dir/key-audit.log" ]; then
      touch "$keys_dir/key-audit.log"
    fi
  fi
}

# ── Audit logging ─────────────────────────────────────────────────────────────

# log_key_operation <stack> <operation> <details> [--failed] [--args <args>]
# Logs a key operation to the audit log
log_key_operation() {
  local stack="$1"
  local operation="$2"
  local details="$3"
  shift 3 || true

  local failed=false
  local args=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --failed) failed=true; shift ;;
      --args=*) args="${1#*=}"; shift ;;
      --args)   args="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local audit_log="$keys_dir/key-audit.log"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local user="${USER:-unknown}"
  local hostname="${HOSTNAME:-$(hostname 2>/dev/null || echo 'unknown')}"

  local status="SUCCESS"
  if $failed; then
    status="FAILED"
  fi

  # Format: [timestamp] user@hostname: operation [status] - details [args: ...]
  local log_entry="[$timestamp] $user@$hostname: $operation [$status] - $details"
  if [ -n "$args" ]; then
    log_entry="$log_entry [args: $args]"
  fi

  echo "$log_entry" >> "$audit_log"
}

# ── Main command dispatcher ───────────────────────────────────────────────────

# keys_command <stack> <subcommand> [--env-file <path>] [args...]
# Main entry point for key management commands
keys_command() {
  local stack="$1"
  local subcommand="${2:-}"
  shift 2 || true

  # Extract --env-file from args before passing remainder to subcommands
  local env_file="$CLI_ROOT/.prod.env"
  local filtered_args=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --env-file=*) env_file="${1#*=}"; shift ;;
      --env-file)   env_file="$2"; shift 2 ;;
      *)            filtered_args+=("$1"); shift ;;
    esac
  done
  set -- "${filtered_args[@]+"${filtered_args[@]}"}"

  # Ensure keys directory exists
  ensure_keys_dir "$stack"

  case "$subcommand" in
    # Discovery & Inventory
    discover)       keys_discover "$stack" "$@" ;;
    inventory)      keys_inventory "$stack" "$@" ;;
    audit)          keys_audit "$stack" "$@" ;;
    export)         keys_export "$stack" "$@" ;;
    status)         keys_status "$stack" "$@" ;;
    recent)         keys_recent "$stack" "$@" ;;

    # Testing & Verification
    test)           keys_test_all "$stack" "$@" ;;
    test:ssh)       keys_test_ssh_all "$stack" "$@" ;;
    test:vps)       keys_test_vps "$stack" "$@" ;;
    test:env)       keys_test_env "$stack" "$@" ;;
    test:api)       keys_test_api "$stack" "$@" ;;
    test:db)        keys_test_db "$stack" "$@" ;;
    test:github)    keys_test_github "$stack" "$@" ;;

    # SSH key management
    ssh:add)        keys_ssh_add "$stack" "$env_file" "$@" ;;
    ssh:rotate)     keys_ssh_rotate "$stack" "$env_file" "$@" ;;
    ssh:revoke)     keys_ssh_revoke "$stack" "$env_file" "$@" ;;
    ssh:list)       keys_ssh_list "$stack" "$@" ;;
    ssh:audit)      keys_ssh_audit "$stack" "$env_file" "$@" ;;
    ssh:sync-github) keys_ssh_sync_github "$stack" "$@" ;;

    # API key management
    api:generate)   keys_api_generate "$stack" "$@" ;;
    api:rotate)     keys_api_rotate "$stack" "$@" ;;
    api:revoke)     keys_api_revoke "$stack" "$@" ;;
    api:list)       keys_api_list "$stack" "$@" ;;
    api:test)       keys_api_test "$stack" "$@" ;;

    # Environment variable management
    env:rotate)     keys_env_rotate "$stack" "$@" ;;
    env:set)        keys_env_set "$stack" "$@" ;;
    env:sync)       keys_env_sync "$stack" "$@" ;;
    env:validate)   keys_env_validate "$stack" "$@" ;;
    env:backup)     keys_env_backup "$stack" "$@" ;;
    env:diff)       keys_env_diff "$stack" "$@" ;;

    # Database credential management
    db:rotate)      keys_db_rotate "$stack" "$@" ;;
    db:create-readonly) keys_db_create_readonly "$stack" "$@" ;;

    # Pull keys from VPS
    pull)           keys_pull "$stack" "$@" ;;

    # GitHub secrets management
    github:list)    keys_github_list "$@" ;;
    github:set)     keys_github_set "$@" ;;
    github:rotate-vps-key) keys_github_rotate_vps_key "$stack" "$@" ;;
    github:rotate-pat) keys_github_rotate_pat "$@" ;;
    github:sync)    keys_github_sync "$stack" "$@" ;;
    github:audit)   keys_github_audit "$@" ;;

    *)
      echo ""
      echo -e "${BLUE}Key Management Commands${NC}"
      echo ""
      echo "Status & Monitoring:"
      echo "  status [--json]                         Show health of all keys"
      echo "  recent [--limit <n>]                    Show recent operations (default: 10)"
      echo ""
      echo "Testing & Verification:"
      echo "  test                                    Test all keys"
      echo "  test:ssh                                Test SSH key connectivity"
      echo "  test:vps                                Test VPS connection"
      echo "  test:env                                Test environment configuration"
      echo "  test:api <name>                         Test API key"
      echo "  test:db <postgres|neo4j>                Test database connection"
      echo "  test:github                             Test GitHub CLI access"
      echo ""
      echo "Discovery & Inventory:"
      echo "  discover [--scan-repos] [--scan-vps]    Discover all keys across systems"
      echo "  inventory [--json]                      Show all keys and their status"
      echo "  audit [--expired] [--unused]            Audit key age and usage"
      echo "  export [--format json|csv]              Export key metadata"
      echo "  pull [--from <source>] [--output <file>] [--dry-run]"
      echo "                                          Pull key values from VPS/containers"
      echo ""
      echo "SSH Key Management:"
      echo "  ssh:add <username> [--key-file <path>] [--generate] [--dry-run] [--force]"
      echo "  ssh:rotate <username> [--dry-run]"
      echo "  ssh:revoke <username> [--dry-run] [--force]"
      echo "  ssh:list [--json]"
      echo "  ssh:audit"
      echo "  ssh:sync-github <username> --repo <org/repo> --secret-name <name>"
      echo ""
      echo "API Key Management:"
      echo "  api:generate <name> [--tier standard|privileged] [--dry-run]"
      echo "  api:rotate <name> [--dry-run]"
      echo "  api:revoke <name> [--dry-run] [--force]"
      echo "  api:list [--json]"
      echo "  api:test <name>"
      echo ""
      echo "Environment Variable Management:"
      echo "  env:rotate [--services <list>] [--dry-run] [--force]"
      echo "  env:set <key> <value> [--encrypt] [--dry-run]"
      echo "  env:sync"
      echo "  env:validate"
      echo "  env:backup [--encrypt]"
      echo "  env:diff --local <file> --remote"
      echo ""
      echo "Database Credentials:"
      echo "  db:rotate <neo4j|postgres> [--dry-run] [--force]"
      echo "  db:create-readonly <username>"
      echo ""
      echo "GitHub Secrets:"
      echo "  github:list --repo <org/repo>"
      echo "  github:set --repo <org/repo> --name <secret> --value-from <file>"
      echo "  github:rotate-vps-key --repos <repo1,repo2,...>"
      echo "  github:rotate-pat --repos <pattern>"
      echo "  github:sync --repo <org/repo> --from <env-file>"
      echo "  github:audit --org <org>"
      echo ""
      echo "Common Flags:"
      echo "  --dry-run    Show what would be changed without making changes"
      echo "  --force      Skip confirmation prompts (use with caution)"
      echo "  --json       Output in JSON format"
      echo ""
      echo "Examples:"
      echo "  strut my-stack keys status"
      echo "  strut my-stack keys recent --limit 20"
      echo "  strut my-stack keys test"
      echo "  strut my-stack keys ssh:add alice --generate --dry-run"
      echo ""
      [ -n "$subcommand" ] && fail "Unknown keys subcommand: $subcommand"
      return 1
      ;;
  esac
}
