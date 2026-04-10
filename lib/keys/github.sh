#!/usr/bin/env bash
# ==================================================
# lib/keys/github.sh — GitHub secrets management
# ==================================================

set -euo pipefail

# keys_github_list --repo <org/repo>
keys_github_list() {
  local repo=""

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
      *) shift ;;
    esac
  done

  [ -n "$repo" ] || fail "Usage: keys github:list --repo <org/repo>"

  # Check if gh CLI is available
  require_cmd gh "Install with: brew install gh"

  # Check if authenticated
  if ! gh auth status &>/dev/null; then
    fail "Not authenticated with GitHub CLI. Run: gh auth login"
  fi

  log "Listing GitHub secrets for $repo..."

  gh secret list --repo "$repo"
}

# keys_github_set --repo <org/repo> --name <secret> --value-from <file>
keys_github_set() {
  local repo=""
  local secret_name=""
  local value_from=""

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
      --name=*)
        secret_name="${1#*=}"
        shift
        ;;
      --name)
        secret_name="$2"
        shift 2
        ;;
      --value-from=*)
        value_from="${1#*=}"
        shift
        ;;
      --value-from)
        value_from="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  [ -n "$repo" ] || fail "Missing --repo argument"
  [ -n "$secret_name" ] || fail "Missing --name argument"
  [ -n "$value_from" ] || fail "Missing --value-from argument"
  [ -f "$value_from" ] || fail "File not found: $value_from"

  # Check if gh CLI is available
  require_cmd gh "Install with: brew install gh"

  # Check if authenticated
  if ! gh auth status &>/dev/null; then
    fail "Not authenticated with GitHub CLI. Run: gh auth login"
  fi

  log "Setting GitHub secret $secret_name in $repo..."

  gh secret set "$secret_name" --repo "$repo" <"$value_from"

  ok "GitHub secret set: $secret_name in $repo"
}

# keys_github_rotate_vps_key <stack> --repos <repo1,repo2,...>
keys_github_rotate_vps_key() {
  local stack="$1"
  shift || true

  local repos=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --repos=*)
        repos="${1#*=}"
        shift
        ;;
      --repos)
        repos="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  [ -n "$repos" ] || fail "Usage: keys github:rotate-vps-key --repos <repo1,repo2,...>"

  log "Rotating VPS SSH key and updating GitHub secrets..."

  # Generate new VPS deploy key
  local deploy_user="deploy-bot"
  local key_name="vps-deploy-$(date +%Y%m%d)"

  log "Step 1: Generating new SSH key..."
  keys_ssh_add "$stack" "$deploy_user" --generate

  # Get the new key file
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local metadata_file="$keys_dir/ssh-keys.json"

  local key_file
  key_file=$(jq -r --arg username "$deploy_user" '.ssh_keys[] | select(.username == $username) | .key_file' "$metadata_file" | tail -1)
  local private_key="${key_file%.pub}"

  log "Step 2: Updating GitHub secrets across repos..."

  # Split repos by comma
  IFS=',' read -ra REPO_ARRAY <<<"$repos"

  for repo in "${REPO_ARRAY[@]}"; do
    repo=$(echo "$repo" | xargs) # trim whitespace
    log "  Updating $repo..."
    gh secret set VPS_SSH_KEY --repo "$repo" <"$private_key" 2>&1 | grep -v "✓" || true
    ok "  Updated $repo"
  done

  log "Step 3: Testing new key..."

  # Load VPS connection info
  local env_file="$CLI_ROOT/.prod.env"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"
  set -a
  source "$env_file"
  set +a

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"

  if ssh -i "$private_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$vps_user@$vps_host" "echo 'SSH test successful'" &>/dev/null; then
    ok "New key works!"
  else
    warn "Could not verify new key - please test manually"
  fi

  echo ""
  ok "VPS SSH key rotated and synced to ${#REPO_ARRAY[@]} repositories"
  echo ""
  echo "Updated repos:"
  for repo in "${REPO_ARRAY[@]}"; do
    echo "  - $repo"
  done
  echo ""
  echo "Next steps:"
  echo "  1. Update local .env with new key path: VPS_SSH_KEY=$private_key"
  echo "  2. Test GitHub Actions deployment"
  echo "  3. Remove old key if everything works"
  echo ""
}

# keys_github_rotate_pat --repos <pattern>
keys_github_rotate_pat() {
  local repos=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --repos=*)
        repos="${1#*=}"
        shift
        ;;
      --repos)
        repos="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  [ -n "$repos" ] || fail "Usage: keys github:rotate-pat --repos <pattern>"

  warn "GitHub PAT rotation requires manual steps:"
  echo ""
  echo "1. Generate new PAT at: https://github.com/settings/tokens"
  echo "   Required scopes: repo, read:packages, workflow"
  echo ""
  echo "2. Update GitHub secrets:"

  # Split repos by comma
  IFS=',' read -ra REPO_ARRAY <<<"$repos"

  for repo in "${REPO_ARRAY[@]}"; do
    repo=$(echo "$repo" | xargs)
    echo "   gh secret set GH_PAT --repo $repo"
  done

  echo ""
  echo "3. Update local .env files with new PAT"
  echo ""

  log "This feature requires manual PAT generation for security"
}

# keys_github_sync <stack> --repo <org/repo> --from <env-file>
keys_github_sync() {
  local stack="$1"
  shift || true

  local repo=""
  local env_file=""

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
      --from=*)
        env_file="${1#*=}"
        shift
        ;;
      --from)
        env_file="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  [ -n "$repo" ] || fail "Missing --repo argument"
  [ -n "$env_file" ] || fail "Missing --from argument"
  [ -f "$env_file" ] || fail "Env file not found: $env_file"

  log "Syncing secrets from $env_file to $repo..."

  # Check if gh CLI is available
  require_cmd gh "Install with: brew install gh"

  # Check if authenticated
  if ! gh auth status &>/dev/null; then
    fail "Not authenticated with GitHub CLI. Run: gh auth login"
  fi

  # Define which env vars should be synced to GitHub
  local sync_vars=(
    "VPS_HOST"
    "VPS_USER"
    "VPS_PROJECT_PATH"
    "VPS_STACK_NAME"
    "GH_PAT"
  )

  # Load env file
  set -a
  source "$env_file"
  set +a

  local synced=0
  for var in "${sync_vars[@]}"; do
    local value="${!var:-}"
    if [ -n "$value" ]; then
      log "  Syncing $var..."
      echo "$value" | gh secret set "$var" --repo "$repo" 2>&1 | grep -v "✓" || true
      ((synced++)) || true
    else
      warn "  Skipping $var (not set in $env_file)"
    fi
  done

  ok "Synced $synced secrets to $repo"
}

# keys_github_audit --org <org>
keys_github_audit() {
  local org=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --org=*)
        org="${1#*=}"
        shift
        ;;
      --org)
        org="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  [ -n "$org" ] || fail "Usage: keys github:audit --org <org>"

  # Check if gh CLI is available
  require_cmd gh "Install with: brew install gh"

  # Check if authenticated
  if ! gh auth status &>/dev/null; then
    fail "Not authenticated with GitHub CLI. Run: gh auth login"
  fi

  log "Auditing GitHub secrets for organization: $org..."

  # Get list of repos
  local repos
  repos=$(gh repo list "$org" --json name --jq '.[].name' --limit 100)

  echo ""
  echo -e "${BLUE}GitHub Secrets Audit for $org${NC}"
  echo ""

  local total_repos=0
  local repos_with_secrets=0

  while IFS= read -r repo_name; do
    ((total_repos++)) || true
    local full_repo="$org/$repo_name"

    local secret_count
    secret_count=$(gh secret list --repo "$full_repo" --json name --jq 'length' 2>/dev/null || echo 0)

    if [ "$secret_count" -gt 0 ]; then
      ((repos_with_secrets++)) || true
      echo "  $repo_name: $secret_count secrets"
      gh secret list --repo "$full_repo" --json name --jq '.[] | "    - \(.name)"' 2>/dev/null || true
    fi
  done <<<"$repos"

  echo ""
  echo "Summary:"
  echo "  Total repos: $total_repos"
  echo "  Repos with secrets: $repos_with_secrets"
  echo ""
}
