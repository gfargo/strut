#!/usr/bin/env bash
# ==================================================
# lib/keys/ssh.sh — SSH key management
# ==================================================

set -euo pipefail

# keys_ssh_add <stack> <env_file> <username> [--key-file <path>] [--generate] [--key-name <name>] [--dry-run] [--force]
keys_ssh_add() {
  local stack="$1"
  local env_file="$2"
  local username="${3:-}"
  shift 3 || true

  [ -n "$username" ] || fail "Usage: keys ssh:add <username> [--key-file <path>] [--generate] [--key-name <name>] [--dry-run] [--force]"

  local key_file=""
  local generate=false
  local key_name=""
  local dry_run=false
  local force=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --key-file=*)
        key_file="${1#*=}"
        shift
        ;;
      --key-file)
        if [[ $# -lt 2 || "$2" == --* ]]; then
          fail "--key-file requires a value"
        fi
        key_file="$2"
        shift 2
        ;;
      --key-name=*)
        key_name="${1#*=}"
        shift
        ;;
      --key-name)
        # Guard: next arg must not be another flag
        if [[ $# -lt 2 || "$2" == --* ]]; then
          fail "--key-name requires a value"
        fi
        key_name="$2"
        shift 2
        ;;
      --generate)
        generate=true
        shift
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

  # Load VPS connection info
  validate_env_file "$env_file" VPS_HOST

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"

  # Validate VPS connection
  log "Validating VPS connection..."
  if ! validate_vps_connection "$vps_host" "$vps_user" "$vps_ssh_key" "$vps_port"; then
    fail "Cannot reach VPS at $vps_host. Check VPS_HOST, VPS_USER, and VPS_SSH_KEY in $env_file"
  fi
  ok "VPS is reachable"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Generate or use existing key
  if $generate; then
    log "Generating new SSH key for $username..."
    # Naming: --key-name wins; otherwise <VPS_SSH_KEY_PREFIX><stack>-<username>-<YYYYMMDD>
    # VPS_SSH_KEY_PREFIX defaults to "strut-" and can be set in the env file
    local key_prefix="${VPS_SSH_KEY_PREFIX:-strut-}"
    local key_date
    key_date=$(date +%Y%m%d)
    local resolved_name="${key_name:-${key_prefix}${stack}-${username}-${key_date}}"
    local key_path="$HOME/.ssh/${resolved_name}"

    if $dry_run; then
      show_dry_run_changes "ssh:add" "Generate new SSH key at $key_path and add to VPS"
      return 0
    fi

    ssh-keygen -t ed25519 -C "$username@$stack" -f "$key_path" -N ""
    key_file="${key_path}.pub"
    ok "Generated key: $key_path"
  elif [ -z "$key_file" ]; then
    # Try to find user's default public key
    if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
      key_file="$HOME/.ssh/id_ed25519.pub"
    elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
      key_file="$HOME/.ssh/id_rsa.pub"
    else
      fail "No key file specified and no default key found. Use --key-file or --generate"
    fi
    log "Using default key: $key_file"
  fi

  [ -f "$key_file" ] || fail "Key file not found: $key_file"

  # Validate SSH key format
  if ! validate_ssh_key_format "$key_file"; then
    fail "Invalid SSH public key format in: $key_file"
  fi

  # Read public key
  local pub_key
  pub_key=$(cat "$key_file")

  # Get fingerprint
  local fingerprint
  fingerprint=$(ssh-keygen -lf "$key_file" | awk '{print $2}')

  # Check if key already exists on VPS
  local existing_key
  existing_key=$(ssh $ssh_opts "$vps_user@$vps_host" "grep -F '$pub_key' ~/.ssh/authorized_keys 2>/dev/null || echo ''")

  if [ -n "$existing_key" ]; then
    warn "This key already exists on VPS"
    if ! $force; then
      confirm "Add anyway?" || {
        log "Cancelled"
        return 1
      }
    fi
  fi

  if $dry_run; then
    show_dry_run_changes "ssh:add" "Add SSH key for $username (fingerprint: $fingerprint) to VPS $vps_host"
    return 0
  fi

  log "Adding SSH key for $username to VPS..."

  # Add key to VPS authorized_keys
  ssh $ssh_opts "$vps_user@$vps_host" "
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    echo '$pub_key' >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    # Remove duplicates
    sort -u ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp
    mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
  "

  ok "SSH key added to VPS"

  # Update metadata
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/ssh-keys.json"

  local new_entry
  new_entry=$(jq -n \
    --arg username "$username" \
    --arg fingerprint "$fingerprint" \
    --arg added_date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg key_file "$key_file" \
    '{
      username: $username,
      fingerprint: $fingerprint,
      added_date: $added_date,
      key_file: $key_file,
      last_used: null,
      expires: null,
      synced_to_github: []
    }')

  # Add to metadata (or update if exists)
  local updated_metadata
  updated_metadata=$(jq \
    --argjson entry "$new_entry" \
    --arg username "$username" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.ssh_keys = (.ssh_keys | map(select(.username != $username))) + [$entry] | .last_updated = $ts' \
    "$metadata_file")

  echo "$updated_metadata" >"$metadata_file"

  log_key_operation "$stack" "ssh:add" "Added SSH key for $username (fingerprint: $fingerprint)"

  echo ""
  ok "SSH key added successfully"
  echo ""
  echo "Next steps:"
  echo "  1. Test SSH access: ssh -i ${key_file%.pub} $vps_user@$vps_host"
  echo "  2. Update VPS_SSH_KEY in your env file: VPS_SSH_KEY=${key_file%.pub}"
  echo "  3. Sync to GitHub: strut $stack keys ssh:sync-github $username --repo <org/repo>"
  echo ""
}

# keys_ssh_rotate <stack> <env_file> <username>
keys_ssh_rotate() {
  local stack="$1"
  local env_file="$2"
  local username="${3:-}"

  [ -n "$username" ] || fail "Usage: keys ssh:rotate <username>"

  log "Rotating SSH key for $username..."

  # Revoke old key
  keys_ssh_revoke "$stack" "$env_file" "$username" --no-confirm

  # Generate and add new key
  keys_ssh_add "$stack" "$env_file" "$username" --generate

  ok "SSH key rotated for $username"
}

# keys_ssh_revoke <stack> <env_file> <username> [--no-confirm] [--dry-run] [--force]
keys_ssh_revoke() {
  local stack="$1"
  local env_file="$2"
  local username="${3:-}"
  shift 3 || true

  [ -n "$username" ] || fail "Usage: keys ssh:revoke <username> [--no-confirm] [--dry-run] [--force]"

  local no_confirm=false
  local dry_run=false
  local force=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-confirm)
        no_confirm=true
        shift
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

  # Load metadata
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/ssh-keys.json"

  local fingerprint
  fingerprint=$(jq -r --arg username "$username" '.ssh_keys[] | select(.username == $username) | .fingerprint' "$metadata_file")

  if [ -z "$fingerprint" ]; then
    warn "No SSH key found for $username in metadata"
    return 1
  fi

  # Check if this is the last admin key
  if ! $force && ! check_last_admin_key "$stack" "$username"; then
    error "Cannot revoke last admin SSH key for $username"
    echo ""
    echo "This would lock you out of the VPS!"
    echo "Add another admin key first, or use --force to override (dangerous)"
    echo ""
    return 1
  fi

  if $dry_run; then
    show_dry_run_changes "ssh:revoke" "Revoke SSH key for $username (fingerprint: $fingerprint)"
    return 0
  fi

  if ! $no_confirm; then
    echo ""
    warn "This will revoke SSH access for $username (fingerprint: $fingerprint)"
    confirm "Continue?" || {
      log "Cancelled"
      return 1
    }
  fi

  # Load VPS connection info
  validate_env_file "$env_file" VPS_HOST

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"

  # Validate VPS connection
  if ! validate_vps_connection "$vps_host" "$vps_user" "$vps_ssh_key" "$vps_port"; then
    fail "Cannot reach VPS at $vps_host. Check connection and try again"
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  log "Revoking SSH key from VPS..."

  # Remove key from VPS (by fingerprint pattern)
  ssh $ssh_opts "$vps_user@$vps_host" "
    if [ -f ~/.ssh/authorized_keys ]; then
      # Backup
      cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.backup
      # Remove lines containing the fingerprint comment (username)
      grep -v '$username' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp || true  # no match is fine
      mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys
    fi
  "

  ok "SSH key revoked from VPS"

  # Update metadata
  local updated_metadata
  updated_metadata=$(jq \
    --arg username "$username" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.ssh_keys = (.ssh_keys | map(select(.username != $username))) | .last_updated = $ts' \
    "$metadata_file")

  echo "$updated_metadata" >"$metadata_file"

  log_key_operation "$stack" "ssh:revoke" "Revoked SSH key for $username (fingerprint: $fingerprint)"

  ok "SSH key revoked successfully"
}

# keys_ssh_list <stack> [--json]
keys_ssh_list() {
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
  local metadata_file="$keys_dir/ssh-keys.json"

  if $json_output; then
    jq '.ssh_keys' "$metadata_file"
  else
    echo ""
    echo -e "${BLUE}SSH Keys for $stack${NC}"
    echo ""

    local count
    count=$(jq '.ssh_keys | length' "$metadata_file")

    if [ "$count" -eq 0 ]; then
      echo "  No SSH keys tracked"
    else
      jq -r '.ssh_keys[] | "  \(.username)\n    Fingerprint: \(.fingerprint)\n    Added: \(.added_date)\n    Synced to GitHub: \(.synced_to_github | length) repos\n"' "$metadata_file"
    fi

    echo ""
  fi
}

# keys_ssh_audit <stack> <env_file>
keys_ssh_audit() {
  local stack="$1"
  local env_file="$2"

  log "Auditing SSH keys..."

  # Load VPS connection info
  validate_env_file "$env_file" VPS_HOST

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Get actual keys from VPS
  local vps_keys
  vps_keys=$(ssh $ssh_opts "$vps_user@$vps_host" "cat ~/.ssh/authorized_keys 2>/dev/null || echo ''")

  local vps_count
  vps_count=$(echo "$vps_keys" | grep -c "^ssh-" || echo 0)

  # Get tracked keys
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/ssh-keys.json"
  local tracked_count
  tracked_count=$(jq '.ssh_keys | length' "$metadata_file")

  echo ""
  echo -e "${BLUE}SSH Key Audit for $stack${NC}"
  echo ""
  echo "  VPS authorized_keys: $vps_count keys"
  echo "  Tracked in metadata: $tracked_count keys"
  echo ""

  if [ "$vps_count" -ne "$tracked_count" ]; then
    warn "Mismatch detected! VPS has $vps_count keys but metadata tracks $tracked_count"
    echo ""
    echo "Run discovery to sync: strut $stack keys discover --scan-vps"
  else
    ok "Counts match"
  fi

  echo ""
}

# keys_ssh_sync_github <stack> <username> --repo <org/repo> --secret-name <name>
keys_ssh_sync_github() {
  local stack="$1"
  local username="${2:-}"
  shift 2 || true

  [ -n "$username" ] || fail "Usage: keys ssh:sync-github <username> --repo <org/repo> --secret-name <name>"

  local repo=""
  local secret_name="VPS_SSH_KEY"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --repo=*)
        repo="${1#*=}"
        shift
        ;;
      --repo)
        repo="$2"
        shift 2
        ;;
      --secret-name=*)
        secret_name="${1#*=}"
        shift
        ;;
      --secret-name)
        secret_name="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  [ -n "$repo" ] || fail "Missing --repo argument"

  # Check if gh CLI is available
  require_cmd gh "Install with: brew install gh"

  # Check if authenticated
  if ! gh auth status &>/dev/null; then
    fail "Not authenticated with GitHub CLI. Run: gh auth login"
  fi

  # Get key file from metadata
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/ssh-keys.json"

  local key_file
  key_file=$(jq -r --arg username "$username" '.ssh_keys[] | select(.username == $username) | .key_file' "$metadata_file")

  if [ -z "$key_file" ] || [ "$key_file" = "null" ]; then
    fail "No key file found for $username in metadata"
  fi

  # Get private key path
  local private_key="${key_file%.pub}"
  [ -f "$private_key" ] || fail "Private key not found: $private_key"

  log "Syncing SSH key to GitHub secret $secret_name in $repo..."

  # Set GitHub secret
  gh secret set "$secret_name" --repo "$repo" <"$private_key"

  ok "SSH key synced to GitHub"

  # Update metadata
  local updated_metadata
  updated_metadata=$(jq \
    --arg username "$username" \
    --arg repo "$repo" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '(.ssh_keys[] | select(.username == $username) | .synced_to_github) |= (. + [$repo] | unique) | .last_updated = $ts' \
    "$metadata_file")

  echo "$updated_metadata" >"$metadata_file"

  log_key_operation "$stack" "ssh:sync-github" "Synced SSH key for $username to $repo as $secret_name"

  echo ""
  ok "GitHub secret updated: $secret_name in $repo"
  echo ""
}
