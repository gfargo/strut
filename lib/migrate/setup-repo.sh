#!/usr/bin/env bash
# ==================================================
# lib/migrate/setup-repo.sh — Repository setup logic
# ==================================================

# Setup strut repository on VPS with deploy key (recommended)
# Usage: setup_repo_with_deploy_key <vps_user> <vps_host> <ssh_port> <ssh_key> <git_url> <dest_dir>
set -euo pipefail

setup_repo_with_deploy_key() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local git_url="$5"
  local dest_dir="$6"

  log "Generating dedicated deploy key for strut..."

  # Generate deploy key
  local key_name="strut_deploy_key"
  local comment="strut@$vps_host"
  local public_key

  public_key=$(generate_deploy_key "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$key_name" "$comment")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Add this deploy key to GitHub repository:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$public_key"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Steps:"
  echo "  1. Go to your repository's Settings → Deploy keys"
  echo "  2. Click 'Add deploy key'"
  echo "  3. Title: $vps_host-strut"
  echo "  4. Paste the key above"
  echo "  5. Read-only access is sufficient"
  echo ""
  read -p "Press Enter after adding the deploy key to GitHub..."

  # Configure SSH
  log "Configuring SSH to use deploy key..."
  local host_alias="github.com-strut"
  configure_deploy_key_ssh "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$key_name" "$host_alias"

  # Clone
  log "Cloning strut with deploy key..."
  if clone_with_deploy_key "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$git_url" "$host_alias" "$dest_dir"; then
    ok "strut cloned with deploy key"
    return 0
  else
    fail "Failed to clone repository. Please verify the deploy key was added correctly."
    return 1
  fi
}

# Setup strut repository on VPS with PAT
# Usage: setup_repo_with_pat <vps_user> <vps_host> <ssh_port> <ssh_key> <https_url> <dest_dir>
setup_repo_with_pat() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local https_url="$5"
  local dest_dir="$6"

  echo ""
  echo "Create a Personal Access Token:"
  echo "  1. Go to: https://github.com/settings/tokens?type=beta"
  echo "  2. Generate new token"
  echo "  3. Repository access: Only select repositories → strut"
  echo "  4. Permissions: Contents (read), Metadata (read)"
  echo "  5. Expiration: 90 days"
  echo ""
  read -sp "Enter GitHub Personal Access Token: " github_pat
  echo ""

  if [ -z "$github_pat" ]; then
    fail "PAT is required to clone private repository"
    return 1
  fi

  log "Cloning with PAT authentication..."
  if clone_with_pat "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$https_url" "$github_pat" "$dest_dir"; then
    ok "strut cloned with PAT"
    return 0
  else
    fail "Failed to clone repository with PAT"
    return 1
  fi
}

# Main repository setup function
# Usage: setup_strut_repo <vps_user> <vps_host> <ssh_port> <ssh_key> <git_url> <dest_dir>
setup_strut_repo() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local git_url="$5"
  local dest_dir="$6"

  # Detect URL type
  local url_type
  url_type=$(detect_url_type "$git_url")

  log "Detected repository: $git_url (type: $url_type)"

  # Check if it's a private repo
  if ! echo "$git_url" | grep -qE "(github\.com|gitlab\.com)"; then
    # Not GitHub/GitLab, try direct clone
    log "Cloning from: $git_url"
    ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
      "git clone $git_url $dest_dir"
    return $?
  fi

  # It's a GitHub/GitLab repo - handle authentication
  if [ "$url_type" = "ssh" ]; then
    # SSH URL - test access first
    log "Testing SSH access to repository..."

    if test_github_repo_access "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$git_url"; then
      ok "VPS already has SSH access to repository"
      log "Cloning from: $git_url"
      ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
        "git clone $git_url $dest_dir"
      return $?
    else
      warn "VPS does not have SSH access to repository"
      echo ""
      echo "This usually means:"
      echo "  - No SSH key exists on VPS, OR"
      echo "  - Existing SSH key is not added to GitHub, OR"
      echo "  - Existing SSH key is a deploy key for another repository"
      echo ""
      echo "Authentication options:"
      echo "  1. Generate new deploy key for strut (recommended)"
      echo "  2. Switch to HTTPS with Personal Access Token"
      echo ""
      read -p "Choose authentication method (1/2): " -r auth_choice

      case "$auth_choice" in
        1)
          setup_repo_with_deploy_key "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$git_url" "$dest_dir"
          ;;
        2)
          # Convert SSH URL to HTTPS
          local https_url
          https_url=$(echo "$git_url" | sed 's|git@github.com:|https://github.com/|' | sed 's|\.git$||')
          setup_repo_with_pat "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$https_url" "$dest_dir"
          ;;
        *)
          fail "Invalid authentication method selected"
          return 1
          ;;
      esac
    fi
  elif [ "$url_type" = "https" ]; then
    # HTTPS URL - offer PAT or deploy key
    warn "This is a private repository requiring authentication."
    echo ""
    echo "Authentication options:"
    echo "  1. Personal Access Token (PAT) - Quick"
    echo "  2. Deploy key (read-only, more secure)"
    echo ""
    read -p "Choose authentication method (1/2): " -r auth_choice

    case "$auth_choice" in
      1)
        setup_repo_with_pat "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$git_url" "$dest_dir"
        ;;
      2)
        # Convert HTTPS URL to SSH
        local ssh_url
        ssh_url=$(echo "$git_url" | sed 's|https://github.com/|git@github.com:|')
        setup_repo_with_deploy_key "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" "$ssh_url" "$dest_dir"
        ;;
      *)
        fail "Invalid authentication method selected"
        return 1
        ;;
    esac
  else
    fail "Unknown URL type: $git_url"
    return 1
  fi
}
