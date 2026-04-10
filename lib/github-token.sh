#!/usr/bin/env bash
# ==================================================
# github-token.sh — GitHub fine-grained token management
# ==================================================
#
# Functions for creating and managing fine-grained PATs
# for VPS deployments

# github_create_fine_grained_token <vps_host> <repo_owner> <repo_name>
# Creates a fine-grained PAT with minimal permissions for strut
set -euo pipefail

github_create_fine_grained_token() {
  local vps_host="$1"
  local repo_owner="${2:-${DEFAULT_ORG:-}}"
  local repo_name="${3:-strut}"

  [ -n "$vps_host" ] || fail "Usage: github_create_fine_grained_token <vps_host> [repo_owner] [repo_name]"
  [ -n "$repo_owner" ] || fail "pass --org or set DEFAULT_ORG in strut.conf"

  log "Creating fine-grained token for $vps_host..."

  # Check if gh CLI is available and authenticated
  if ! command -v gh &>/dev/null; then
    warn "GitHub CLI (gh) not installed"
    echo "Install: https://cli.github.com/"
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    warn "GitHub CLI not authenticated"
    echo "Run: gh auth login"
    return 1
  fi

  # Get repository ID
  local repo_id
  repo_id=$(gh api "/repos/$repo_owner/$repo_name" --jq '.id' 2>/dev/null)

  if [ -z "$repo_id" ]; then
    warn "Could not get repository ID for $repo_owner/$repo_name"
    return 1
  fi

  log "Repository ID: $repo_id"

  # Generate token name
  local token_name="strut-${vps_host}-$(date +%Y%m%d-%H%M%S)"

  # Calculate expiration (90 days from now)
  local expires_at
  if command -v gdate &>/dev/null; then
    # macOS with GNU date
    expires_at=$(gdate -d "+90 days" -u +"%Y-%m-%dT%H:%M:%SZ")
  elif date --version 2>&1 | grep -q "GNU"; then
    # Linux with GNU date
    expires_at=$(date -d "+90 days" -u +"%Y-%m-%dT%H:%M:%SZ")
  else
    # BSD date (macOS default)
    expires_at=$(date -u -v+90d +"%Y-%m-%dT%H:%M:%SZ")
  fi

  log "Token will expire: $expires_at"

  # Create fine-grained token via GitHub API
  # Note: This requires the user's current token to have admin:personal_access_token scope
  local response
  response=$(gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    /user/personal_access_tokens \
    -f "name=$token_name" \
    -f "description=strut access for VPS $vps_host (auto-generated)" \
    -f "expires_at=$expires_at" \
    -f "repositories[]=$repo_name" \
    -F "permissions[contents]=read" \
    -F "permissions[metadata]=read" \
    2>&1)

  # Check if token creation succeeded
  if echo "$response" | grep -q "token"; then
    local new_token
    new_token=$(echo "$response" | jq -r '.token' 2>/dev/null)

    if [ -n "$new_token" ] && [ "$new_token" != "null" ]; then
      ok "Fine-grained token created: $token_name"
      echo "$new_token"
      return 0
    fi
  fi

  # Token creation failed - likely due to permissions
  if echo "$response" | grep -q "personal_access_token"; then
    warn "Cannot create fine-grained token - missing permissions"
    echo ""
    echo "Your current GitHub token needs 'admin:personal_access_token' scope."
    echo ""
    echo "To enable automated token creation:"
    echo "  1. Run: gh auth refresh -s admin:personal_access_token"
    echo "  2. Re-run the migration wizard"
    echo ""
    echo "Or create token manually:"
    echo "  1. Go to: https://github.com/settings/tokens?type=beta"
    echo "  2. Generate new token"
    echo "  3. Repository access: Only select repositories → $repo_name"
    echo "  4. Permissions: Contents (read), Metadata (read)"
    echo "  5. Expiration: 90 days"
    echo ""
    return 1
  else
    warn "Failed to create token: $response"
    return 1
  fi
}

# github_list_fine_grained_tokens
# Lists all fine-grained tokens for the authenticated user
github_list_fine_grained_tokens() {
  if ! command -v gh &>/dev/null; then
    warn "GitHub CLI (gh) not installed"
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    warn "GitHub CLI not authenticated"
    return 1
  fi

  log "Fetching fine-grained tokens..."

  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    /user/personal_access_tokens \
    --jq '.[] | select(.name | startswith("strut-")) | {name: .name, expires_at: .expires_at, repositories: [.repositories[].name]}'
}

# github_revoke_token <token_id>
# Revokes a fine-grained token
github_revoke_token() {
  local token_id="$1"

  [ -n "$token_id" ] || fail "Usage: github_revoke_token <token_id>"

  if ! command -v gh &>/dev/null; then
    warn "GitHub CLI (gh) not installed"
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    warn "GitHub CLI not authenticated"
    return 1
  fi

  log "Revoking token: $token_id"

  gh api \
    --method DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/user/personal_access_tokens/$token_id"

  ok "Token revoked"
}

# github_check_token_permissions
# Checks if current gh token has permissions to create fine-grained tokens
github_check_token_permissions() {
  if ! command -v gh &>/dev/null; then
    echo "not_installed"
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    echo "not_authenticated"
    return 1
  fi

  # Try to list tokens - if this works, we have the right permissions
  if gh api /user/personal_access_tokens &>/dev/null; then
    echo "has_permissions"
    return 0
  else
    echo "missing_permissions"
    return 1
  fi
}

# github_setup_token_permissions
# Guides user through setting up gh CLI with correct permissions
github_setup_token_permissions() {
  echo ""
  echo -e "${BLUE}Setting up GitHub CLI for automated token creation${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local status
  status=$(github_check_token_permissions)

  case "$status" in
    not_installed)
      warn "GitHub CLI (gh) not installed"
      echo ""
      echo "Install GitHub CLI:"
      echo "  macOS:   brew install gh"
      echo "  Linux:   See https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
      echo "  Windows: See https://github.com/cli/cli#installation"
      echo ""
      return 1
      ;;

    not_authenticated)
      warn "GitHub CLI not authenticated"
      echo ""
      echo "Authenticate with GitHub:"
      echo "  gh auth login"
      echo ""
      echo "Then grant the required scope:"
      echo "  gh auth refresh -s admin:personal_access_token"
      echo ""
      return 1
      ;;

    missing_permissions)
      warn "GitHub CLI token missing required permissions"
      echo ""
      echo "Grant the required scope:"
      echo "  gh auth refresh -s admin:personal_access_token"
      echo ""
      echo "This allows the wizard to create fine-grained tokens automatically."
      echo ""
      read -p "Run this command now? (yes/no): " -r
      if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        gh auth refresh -s admin:personal_access_token

        if github_check_token_permissions | grep -q "has_permissions"; then
          ok "Permissions granted successfully"
          return 0
        else
          warn "Permission grant failed"
          return 1
        fi
      else
        return 1
      fi
      ;;

    has_permissions)
      ok "GitHub CLI has required permissions"
      return 0
      ;;
  esac
}
