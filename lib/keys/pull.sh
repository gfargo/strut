#!/usr/bin/env bash
# ==================================================
# lib/keys/pull.sh — Pull key values from VPS
# ==================================================
# Extract actual key values from running VPS and populate local key files

# keys_pull <stack> [options]
# Pull key values from VPS to local environment
set -euo pipefail

keys_pull() {
  local stack="$1"
  shift

  local source="vps" # vps, containers, env-file
  local target_file=""
  local container_name=""
  local dry_run=false
  local force=false
  local keys_filter=""
  local output_format="env" # env, json

  # Parse options
  while [[ $# -gt 0 ]]; do
    case $1 in
      --from)
        source="$2"
        shift 2
        ;;
      --container)
        container_name="$2"
        shift 2
        ;;
      --output)
        target_file="$2"
        shift 2
        ;;
      --format)
        output_format="$2"
        shift 2
        ;;
      --keys)
        keys_filter="$2"
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
      *)
        warn "Unknown option: $1"
        shift
        ;;
    esac
  done

  # Get stack directory and keys directory
  local stack_dir="$CLI_ROOT/stacks/$stack"
  local keys_dir="$stack_dir/keys"

  [ -d "$stack_dir" ] || fail "Stack not found: $stack"
  mkdir -p "$keys_dir"

  # Determine target file
  if [ -z "$target_file" ]; then
    target_file="$CLI_ROOT/.${stack}-pulled.env"
  fi

  log "Pulling keys from $source for stack: $stack"

  case "$source" in
    vps)
      keys_pull_from_vps "$stack" "$target_file" "$dry_run" "$force" "$keys_filter" "$output_format"
      ;;
    containers)
      keys_pull_from_containers "$stack" "$container_name" "$target_file" "$dry_run" "$force" "$keys_filter" "$output_format"
      ;;
    env-file)
      keys_pull_from_env_file "$stack" "$target_file" "$dry_run" "$force"
      ;;
    *)
      fail "Unknown source: $source (use: vps, containers, env-file)"
      ;;
  esac
}

# keys_pull_from_vps <stack> <target_file> <dry_run> <force> <keys_filter> <output_format>
# Pull keys from VPS environment file
keys_pull_from_vps() {
  local stack="$1"
  local target_file="$2"
  local dry_run="$3"
  local force="$4"
  local keys_filter="$5"
  local output_format="$6"

  # Load VPS connection info from env
  local env_file="$CLI_ROOT/.prod.env"
  if [ ! -f "$env_file" ]; then
    fail "Environment file not found: $env_file"
  fi

  set -a
  source "$env_file"
  set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_deploy_dir="${VPS_DEPLOY_DIR:-/home/${vps_user}/strut}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

  log "Connecting to VPS: $vps_user@$vps_host"

  # Validate connection
  if ! validate_vps_connection "$vps_host" "$vps_user" "$vps_ssh_key" 10; then
    fail "Cannot connect to VPS: $vps_host"
  fi

  ok "VPS connection validated"

  # Build SSH command
  local ssh_opts
  ssh_opts=$(build_ssh_opts -k "$vps_ssh_key" --batch)

  # Find env file on VPS
  local remote_env_file="$vps_deploy_dir/.prod.env"
  log "Looking for env file on VPS: $remote_env_file"

  # Check if file exists
  if ! ssh $ssh_opts "$vps_user@$vps_host" "test -f $remote_env_file" 2>/dev/null; then
    warn "Env file not found on VPS: $remote_env_file"
    log "Trying alternative locations..."

    # Try to find env files
    local found_env_files
    found_env_files=$(ssh $ssh_opts "$vps_user@$vps_host" "find $vps_deploy_dir -maxdepth 1 -name '*.env' 2>/dev/null" || echo "")

    if [ -n "$found_env_files" ]; then
      log "Found env files on VPS:"
      echo "$found_env_files"

      # Use first found file
      remote_env_file=$(echo "$found_env_files" | head -1)
      log "Using: $remote_env_file"
    else
      fail "No env files found on VPS in $vps_deploy_dir"
    fi
  fi

  ok "Found env file: $remote_env_file"

  # Pull env file content
  log "Pulling env file content..."
  local env_content
  env_content=$(ssh $ssh_opts "$vps_user@$vps_host" "cat $remote_env_file" 2>/dev/null)

  if [ -z "$env_content" ]; then
    fail "Failed to read env file from VPS"
  fi

  # Filter keys if specified
  if [ -n "$keys_filter" ]; then
    log "Filtering keys matching: $keys_filter"
    env_content=$(echo "$env_content" | grep -E "$keys_filter" || true)
  fi

  # Count keys
  local key_count
  key_count=$(echo "$env_content" | grep -c "^[A-Z_].*=" || echo "0")

  log "Found $key_count keys"

  if $dry_run; then
    warn "DRY RUN - Would write to: $target_file"
    echo ""
    echo "Preview of keys (values masked):"
    echo "$env_content" | sed 's/=.*/=***MASKED***/'
    return 0
  fi

  # Check if target file exists
  if [ -f "$target_file" ] && ! $force; then
    warn "Target file already exists: $target_file"
    read -p "Overwrite? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
      fail "Cancelled by user"
    fi
  fi

  # Write to target file
  if [ "$output_format" = "json" ]; then
    # Convert to JSON format
    log "Converting to JSON format..."
    local json_output='{"keys":{},"pulled_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","source":"vps","vps_host":"'$vps_host'"}'

    # Parse env vars into JSON
    while IFS='=' read -r key value; do
      [ -z "$key" ] && continue
      [[ "$key" =~ ^# ]] && continue
      json_output=$(echo "$json_output" | jq --arg k "$key" --arg v "$value" '.keys[$k] = $v')
    done <<<"$env_content"

    echo "$json_output" | jq '.' >"$target_file"
  else
    # Write as env file
    echo "$env_content" >"$target_file"
  fi

  ok "Keys pulled to: $target_file"

  # Security warning
  warn "⚠️  SECURITY: This file contains sensitive secrets!"
  warn "   - Do not commit to git"
  warn "   - Restrict file permissions: chmod 600 $target_file"
  warn "   - Delete after use if not needed"

  # Set restrictive permissions
  chmod 600 "$target_file"
  ok "File permissions set to 600 (owner read/write only)"

  # Show summary
  echo ""
  echo "Summary:"
  echo "  Keys pulled: $key_count"
  echo "  Source: $vps_host:$remote_env_file"
  echo "  Target: $target_file"
  echo "  Format: $output_format"
  echo ""
  echo "Next steps:"
  echo "  1. Review keys: cat $target_file"
  echo "  2. Copy to stack env: cp $target_file .$stack-prod.env"
  echo "  3. Delete pulled file: rm $target_file"
}

# keys_pull_from_containers <stack> <container_name> <target_file> <dry_run> <force> <keys_filter> <output_format>
# Pull keys from running Docker containers
keys_pull_from_containers() {
  local stack="$1"
  local container_name="$2"
  local target_file="$3"
  local dry_run="$4"
  local force="$5"
  local keys_filter="$6"
  local output_format="$7"

  # Load VPS connection info
  local env_file="$CLI_ROOT/.prod.env"
  if [ ! -f "$env_file" ]; then
    fail "Environment file not found: $env_file"
  fi

  set -a
  source "$env_file"
  set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set in $env_file"

  log "Connecting to VPS: $vps_user@$vps_host"

  # Validate connection
  if ! validate_vps_connection "$vps_host" "$vps_user" "$vps_ssh_key" 10; then
    fail "Cannot connect to VPS: $vps_host"
  fi

  ok "VPS connection validated"

  # Build SSH command
  local ssh_opts
  ssh_opts=$(build_ssh_opts -k "$vps_ssh_key" --batch)

  # If no container specified, list containers and let user choose
  if [ -z "$container_name" ]; then
    log "Listing containers on VPS..."
    local containers
    containers=$(ssh $ssh_opts "$vps_user@$vps_host" "$(vps_sudo_prefix)docker ps --format '{{.Names}}'" 2>/dev/null)

    if [ -z "$containers" ]; then
      fail "No running containers found on VPS"
    fi

    echo ""
    echo "Available containers:"
    echo "$containers" | nl
    echo ""
    read -p "Enter container name or number: " -r

    if [[ "$REPLY" =~ ^[0-9]+$ ]]; then
      container_name=$(echo "$containers" | sed -n "${REPLY}p")
    else
      container_name="$REPLY"
    fi

    [ -n "$container_name" ] || fail "No container selected"
  fi

  log "Pulling environment variables from container: $container_name"

  # Get environment variables from container
  local env_content
  env_content=$(ssh $ssh_opts "$vps_user@$vps_host" "$(vps_sudo_prefix)docker exec $container_name env" 2>/dev/null)

  if [ -z "$env_content" ]; then
    fail "Failed to get environment variables from container: $container_name"
  fi

  # Filter out system variables
  env_content=$(echo "$env_content" | grep -vE "^(PATH|HOME|USER|HOSTNAME|PWD|SHLVL|_)=" || true)

  # Filter keys if specified
  if [ -n "$keys_filter" ]; then
    log "Filtering keys matching: $keys_filter"
    env_content=$(echo "$env_content" | grep -E "$keys_filter" || true)
  fi

  # Count keys
  local key_count
  key_count=$(echo "$env_content" | grep -c "=" || echo "0")

  log "Found $key_count keys"

  if $dry_run; then
    warn "DRY RUN - Would write to: $target_file"
    echo ""
    echo "Preview of keys (values masked):"
    echo "$env_content" | sed 's/=.*/=***MASKED***/'
    return 0
  fi

  # Check if target file exists
  if [ -f "$target_file" ] && ! $force; then
    warn "Target file already exists: $target_file"
    read -p "Overwrite? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
      fail "Cancelled by user"
    fi
  fi

  # Write to target file
  if [ "$output_format" = "json" ]; then
    # Convert to JSON format
    log "Converting to JSON format..."
    local json_output='{"keys":{},"pulled_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","source":"container","container":"'$container_name'","vps_host":"'$vps_host'"}'

    # Parse env vars into JSON
    while IFS='=' read -r key value; do
      [ -z "$key" ] && continue
      json_output=$(echo "$json_output" | jq --arg k "$key" --arg v "$value" '.keys[$k] = $v')
    done <<<"$env_content"

    echo "$json_output" | jq '.' >"$target_file"
  else
    # Write as env file
    echo "$env_content" >"$target_file"
  fi

  ok "Keys pulled to: $target_file"

  # Security warning
  warn "⚠️  SECURITY: This file contains sensitive secrets!"
  warn "   - Do not commit to git"
  warn "   - Restrict file permissions: chmod 600 $target_file"
  warn "   - Delete after use if not needed"

  # Set restrictive permissions
  chmod 600 "$target_file"
  ok "File permissions set to 600 (owner read/write only)"

  # Show summary
  echo ""
  echo "Summary:"
  echo "  Keys pulled: $key_count"
  echo "  Source: $vps_host (container: $container_name)"
  echo "  Target: $target_file"
  echo "  Format: $output_format"
  echo ""
  echo "Next steps:"
  echo "  1. Review keys: cat $target_file"
  echo "  2. Copy to stack env: cp $target_file .$stack-prod.env"
  echo "  3. Delete pulled file: rm $target_file"
}

# keys_pull_from_env_file <stack> <target_file> <dry_run> <force>
# Pull keys from local env file (useful for copying between stacks)
keys_pull_from_env_file() {
  local stack="$1"
  local target_file="$2"
  local dry_run="$3"
  local force="$4"

  # Find source env file
  local source_file="$CLI_ROOT/.prod.env"

  if [ ! -f "$source_file" ]; then
    # Try stack-specific env file
    source_file="$CLI_ROOT/.$stack-prod.env"
  fi

  if [ ! -f "$source_file" ]; then
    fail "No env file found. Tried: .prod.env, .$stack-prod.env"
  fi

  log "Pulling keys from local env file: $source_file"

  # Read env file
  local env_content
  env_content=$(cat "$source_file")

  # Count keys
  local key_count
  key_count=$(echo "$env_content" | grep -c "^[A-Z_].*=" || echo "0")

  log "Found $key_count keys"

  if $dry_run; then
    warn "DRY RUN - Would write to: $target_file"
    echo ""
    echo "Preview of keys (values masked):"
    echo "$env_content" | sed 's/=.*/=***MASKED***/'
    return 0
  fi

  # Check if target file exists
  if [ -f "$target_file" ] && ! $force; then
    warn "Target file already exists: $target_file"
    read -p "Overwrite? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
      fail "Cancelled by user"
    fi
  fi

  # Copy file
  cp "$source_file" "$target_file"
  chmod 600 "$target_file"

  ok "Keys copied to: $target_file"

  echo ""
  echo "Summary:"
  echo "  Keys copied: $key_count"
  echo "  Source: $source_file"
  echo "  Target: $target_file"
}

# keys_pull_help
# Show help for keys:pull command
keys_pull_help() {
  cat <<'EOF'
Pull Key Values from VPS

Usage:
  strut <stack> keys:pull [options]

Options:
  --from <source>          Source to pull from (vps, containers, env-file)
  --container <name>       Container name (for --from containers)
  --output <file>          Output file (default: .<stack>-pulled.env)
  --format <format>        Output format (env, json)
  --keys <pattern>         Filter keys by regex pattern
  --dry-run                Show what would be pulled without pulling
  --force                  Overwrite existing file without confirmation

Sources:
  vps                      Pull from VPS env file (.prod.env)
  containers               Pull from running Docker container
  env-file                 Pull from local env file

Examples:
  # Pull all keys from VPS
  strut my-stack keys:pull --from vps

  # Pull from specific container
  strut my-stack keys:pull --from containers --container prod-my-service

  # Pull only database keys
  strut my-stack keys:pull --from vps --keys "DATABASE|POSTGRES|NEO4J"

  # Pull to specific file in JSON format
  strut my-stack keys:pull --from vps --output ./secrets.json --format json

  # Dry run to preview
  strut my-stack keys:pull --from vps --dry-run

Security Notes:
  - Pulled files contain sensitive secrets
  - Files are automatically set to 600 permissions (owner read/write only)
  - Do not commit pulled files to git
  - Delete pulled files after use if not needed

Workflow:
  1. Pull keys from VPS: strut <stack> keys:pull --from vps
  2. Review keys: cat .<stack>-pulled.env
  3. Copy to stack env: cp .<stack>-pulled.env .<stack>-prod.env
  4. Delete pulled file: rm .<stack>-pulled.env

EOF
}
