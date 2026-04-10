#!/usr/bin/env bash
# ==================================================
# lib/keys/discovery.sh — Key discovery across systems
# ==================================================
# Discovers existing keys across VPS, GitHub, and local systems

set -euo pipefail

# ── Discovery functions ───────────────────────────────────────────────────────

# keys_discover <stack> [--scan-repos] [--scan-vps]
# Discovers all keys across systems and generates recommendations
keys_discover() {
  local stack="$1"
  shift

  local scan_repos=false
  local scan_vps=false
  local output_file=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --scan-repos)
        scan_repos=true
        shift
        ;;
      --scan-vps)
        scan_vps=true
        shift
        ;;
      --output=*)
        output_file="${1#*=}"
        shift
        ;;
      --output)
        output_file="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  # If no flags, scan everything
  if ! $scan_repos && ! $scan_vps; then
    scan_repos=true
    scan_vps=true
  fi

  log "Starting key discovery for stack: $stack"
  echo ""

  local discovery_data="{}"
  discovery_data=$(echo "$discovery_data" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '. + {discovered_at: $ts}')

  # Discover local keys
  log "Scanning local environment..."
  local local_data
  local_data=$(discover_local_keys "$stack")
  discovery_data=$(echo "$discovery_data" | jq --argjson local "$local_data" '.sources.local = $local')

  # Discover VPS keys
  if $scan_vps; then
    log "Scanning VPS environment..."
    local vps_data
    vps_data=$(discover_vps_keys "$stack")
    discovery_data=$(echo "$discovery_data" | jq --argjson vps "$vps_data" '.sources.vps = $vps')
  fi

  # Discover GitHub secrets
  if $scan_repos; then
    log "Scanning GitHub repositories..."
    local github_data
    github_data=$(discover_github_secrets "$stack")
    discovery_data=$(echo "$discovery_data" | jq --argjson github "$github_data" '.sources.github = $github')
  fi

  # Generate recommendations
  log "Analyzing discovered keys..."
  local recommendations
  recommendations=$(generate_recommendations "$discovery_data")
  discovery_data=$(echo "$discovery_data" | jq --argjson recs "$recommendations" '.recommendations = $recs')

  # Output results
  echo ""
  echo -e "${GREEN}Discovery Complete${NC}"
  echo ""
  echo "$discovery_data" | jq '.'

  # Save to file if requested
  if [ -n "$output_file" ]; then
    echo "$discovery_data" | jq '.' >"$output_file"
    ok "Discovery results saved to: $output_file"
  fi

  # Save to keys directory
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  echo "$discovery_data" | jq '.' >"$keys_dir/discovery-$(date +%Y%m%d-%H%M%S).json"

  log_key_operation "$stack" "discover" "Completed key discovery scan"
}

# discover_local_keys <stack>
# Discovers keys in local environment
discover_local_keys() {
  local stack="$1"
  local stack_dir="$CLI_ROOT/stacks/$stack"

  local env_files=()
  local ssh_keys=()

  # Find .env files
  if [ -f "$CLI_ROOT/.env" ]; then
    env_files+=(".env")
  fi
  if [ -f "$CLI_ROOT/.prod.env" ]; then
    env_files+=(".prod.env")
  fi
  if [ -f "$stack_dir/.env" ]; then
    env_files+=("stacks/$stack/.env")
  fi

  # Find SSH keys in ~/.ssh
  if [ -d "$HOME/.ssh" ]; then
    while IFS= read -r key; do
      ssh_keys+=("$(basename "$key")")
    done < <(find "$HOME/.ssh" -name "*.pub" -o -name "id_*" ! -name "*.pub" 2>/dev/null | head -10)
  fi

  # Count secrets in .env.template
  local secret_count=0
  if [ -f "$stack_dir/.env.template" ]; then
    secret_count=$(grep -c "^[A-Z_]*=" "$stack_dir/.env.template" 2>/dev/null || echo 0)
  fi

  jq -n \
    --argjson env_files "$(printf '%s\n' "${env_files[@]}" | jq -R . | jq -s .)" \
    --argjson ssh_keys "$(printf '%s\n' "${ssh_keys[@]}" | jq -R . | jq -s .)" \
    --arg secret_count "$secret_count" \
    '{
      env_files: $env_files,
      ssh_keys: $ssh_keys,
      template_secrets: ($secret_count | tonumber)
    }'
}

# discover_vps_keys <stack>
# Discovers keys on VPS
discover_vps_keys() {
  local stack="$1"

  # Load VPS connection info
  local env_file="$CLI_ROOT/.prod.env"
  if [ ! -f "$env_file" ]; then
    echo '{"error": "No .prod.env file found"}'
    return
  fi

  set -a
  source "$env_file"
  set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"

  if [ -z "$vps_host" ]; then
    echo '{"error": "VPS_HOST not set"}'
    return
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -k "$vps_ssh_key" --batch)

  # Count authorized SSH keys
  local ssh_key_count
  ssh_key_count=$(ssh $ssh_opts "$vps_user@$vps_host" "wc -l < ~/.ssh/authorized_keys 2>/dev/null || echo 0" 2>/dev/null || echo 0)

  # List authorized users
  local authorized_users
  authorized_users=$(ssh $ssh_opts "$vps_user@$vps_host" "cat ~/.ssh/authorized_keys 2>/dev/null | grep -oP '(?<=\s)[^\s]+@[^\s]+$' || echo ''" 2>/dev/null || echo "")

  # Check for .env files
  local env_files
  local vps_deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"
  env_files=$(ssh $ssh_opts "$vps_user@$vps_host" "ls -1 $vps_deploy_dir/*.env 2>/dev/null || echo ''" 2>/dev/null || echo "")

  jq -n \
    --arg ssh_key_count "$ssh_key_count" \
    --arg authorized_users "$authorized_users" \
    --arg env_files "$env_files" \
    --arg vps_host "$vps_host" \
    '{
      vps_host: $vps_host,
      ssh_keys: ($ssh_key_count | tonumber),
      authorized_users: ($authorized_users | split("\n") | map(select(length > 0))),
      env_files: ($env_files | split("\n") | map(select(length > 0)))
    }'
}

# discover_github_secrets [stack]
# Discovers GitHub secrets across repositories
# Reads repos from stacks/<stack>/repos.conf if available
discover_github_secrets() {
  local stack="${1:-}"

  # Check if gh CLI is available
  if ! command -v gh &>/dev/null; then
    echo '{"error": "GitHub CLI (gh) not installed"}'
    return
  fi

  # Check if authenticated
  if ! gh auth status &>/dev/null; then
    echo '{"error": "Not authenticated with GitHub CLI"}'
    return
  fi

  # Load repos from stack config or use defaults
  local repos=()
  local repos_source="default"

  if [ -n "$stack" ]; then
    local repos_conf="$CLI_ROOT/stacks/$stack/repos.conf"
    if [ -f "$repos_conf" ]; then
      while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        repos+=("$line")
      done <"$repos_conf"
      repos_source="$repos_conf"
    fi
  fi

  # Fallback: use DEFAULT_ORG to construct repo references, or warn and return empty
  if [ ${#repos[@]} -eq 0 ]; then
    if [ -n "${DEFAULT_ORG:-}" ]; then
      repos=("$DEFAULT_ORG/strut")
      repos_source="DEFAULT_ORG"
      warn "No repos.conf found — using DEFAULT_ORG ($DEFAULT_ORG) to construct repo list"
    else
      warn "No repos.conf found and DEFAULT_ORG not set — skipping GitHub secret discovery"
      jq -n '{repos_scanned: 0, repos_source: "none", secrets_found: {}}'
      return
    fi
  fi

  local secrets_found="{}"
  local repos_scanned=0

  for repo in "${repos[@]}"; do
    local secrets
    secrets=$(gh secret list --repo "$repo" --json name 2>/dev/null | jq -r '.[].name' | jq -R . | jq -s . || echo "[]")
    secrets_found=$(echo "$secrets_found" | jq --arg repo "$repo" --argjson secrets "$secrets" '.[$repo] = $secrets')
    ((repos_scanned++)) || true
  done

  jq -n \
    --arg repos_scanned "$repos_scanned" \
    --arg repos_source "$repos_source" \
    --argjson secrets_found "$secrets_found" \
    '{
      repos_scanned: ($repos_scanned | tonumber),
      repos_source: $repos_source,
      secrets_found: $secrets_found
    }'
}

# generate_recommendations <discovery_data>
# Generates actionable recommendations based on discovered keys
generate_recommendations() {
  local discovery_data="$1"

  local recommendations=()

  # Check for VPS SSH key rotation
  local vps_ssh_keys
  vps_ssh_keys=$(echo "$discovery_data" | jq -r '.sources.vps.ssh_keys // 0')
  if [ "$vps_ssh_keys" -gt 0 ]; then
    recommendations+=("Consider rotating VPS SSH keys (found $vps_ssh_keys authorized keys)")
  fi

  # Check for GitHub secrets
  local github_repos
  github_repos=$(echo "$discovery_data" | jq -r '.sources.github.repos_scanned // 0')
  if [ "$github_repos" -gt 0 ]; then
    recommendations+=("Review GitHub secrets across $github_repos repositories")

    # Check if GH_PAT is used everywhere
    local repos_with_gh_pat
    repos_with_gh_pat=$(echo "$discovery_data" | jq -r '.sources.github.secrets_found | to_entries | map(select(.value | contains(["GH_PAT"]))) | length')
    if [ "$repos_with_gh_pat" -gt 0 ]; then
      recommendations+=("GH_PAT found in $repos_with_gh_pat repos - consider rotation schedule")
    fi
  fi

  # Check for .env files
  local local_env_files
  local_env_files=$(echo "$discovery_data" | jq -r '.sources.local.env_files | length')
  if [ "$local_env_files" -gt 1 ]; then
    recommendations+=("Multiple .env files found ($local_env_files) - ensure they're in sync")
  fi

  # Check template secrets
  local template_secrets
  template_secrets=$(echo "$discovery_data" | jq -r '.sources.local.template_secrets // 0')
  if [ "$template_secrets" -gt 20 ]; then
    recommendations+=("Large number of secrets in template ($template_secrets) - consider secret management solution")
  fi

  printf '%s\n' "${recommendations[@]}" | jq -R . | jq -s .
}
