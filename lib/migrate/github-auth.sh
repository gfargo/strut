#!/usr/bin/env bash
# ==================================================
# lib/migrate/github-auth.sh — GitHub authentication helpers
# ==================================================

# Test if VPS can access a GitHub repository
# Usage: test_github_repo_access <vps_user> <vps_host> <ssh_port> <ssh_key> <git_url>
# Returns: 0 if accessible, 1 if not
set -euo pipefail

test_github_repo_access() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local git_url="$5"

  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "git ls-remote $git_url HEAD &>/dev/null"
}

# Generate deploy key on VPS
# Usage: generate_deploy_key <vps_user> <vps_host> <ssh_port> <ssh_key> <key_name> <comment>
# Returns: public key content
generate_deploy_key() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local key_name="$5"
  local comment="$6"

  # Generate key
  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "ssh-keygen -t ed25519 -C '$comment' -f ~/.ssh/$key_name -N ''" >/dev/null

  # Return public key
  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "cat ~/.ssh/${key_name}.pub"
}

# Configure SSH to use deploy key for GitHub
# Usage: configure_deploy_key_ssh <vps_user> <vps_host> <ssh_port> <ssh_key> <key_name> <host_alias>
configure_deploy_key_ssh() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local key_name="$5"
  local host_alias="$6"

  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "cat >> ~/.ssh/config <<'SSHEOF'

Host $host_alias
    HostName github.com
    User git
    IdentityFile ~/.ssh/$key_name
    StrictHostKeyChecking accept-new
SSHEOF"
}

# Clone repository with deploy key
# Usage: clone_with_deploy_key <vps_user> <vps_host> <ssh_port> <ssh_key> <git_url> <host_alias> <dest_dir>
clone_with_deploy_key() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local git_url="$5"
  local host_alias="$6"
  local dest_dir="$7"

  # Convert git URL to use custom host
  local custom_url
  custom_url=$(echo "$git_url" | sed "s|git@github.com:|git@${host_alias}:|")

  # Clone
  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "git clone $custom_url $dest_dir"

  # Update remote to use custom host for future pulls
  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "cd $dest_dir && git remote set-url origin $custom_url"
}

# Clone repository with PAT
# Usage: clone_with_pat <vps_user> <vps_host> <ssh_port> <ssh_key> <https_url> <pat> <dest_dir>
clone_with_pat() {
  local vps_user="$1"
  local vps_host="$2"
  local ssh_port="$3"
  local ssh_key="$4"
  local https_url="$5"
  local pat="$6"
  local dest_dir="$7"

  # Convert URL to use PAT
  local auth_url
  auth_url=$(echo "$https_url" | sed "s|https://|https://${pat}@|")

  # Clone
  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "git clone $auth_url $dest_dir"

  # Configure git credentials
  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "cd $dest_dir && git config credential.helper store"

  ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
    "echo 'https://${pat}@github.com' > ~/.git-credentials && chmod 600 ~/.git-credentials"
}

# Detect if URL is SSH or HTTPS
# Usage: detect_url_type <git_url>
# Returns: "ssh" or "https" or "unknown"
detect_url_type() {
  local git_url="$1"

  if echo "$git_url" | grep -qE "^git@|^ssh://"; then
    echo "ssh"
  elif echo "$git_url" | grep -q "^https://"; then
    echo "https"
  else
    echo "unknown"
  fi
}

# Extract repo owner and name from GitHub URL
# Usage: extract_repo_info <git_url>
# Returns: "owner/repo"
extract_repo_info() {
  local git_url="$1"

  if echo "$git_url" | grep -q "github.com"; then
    local owner
    local repo
    owner=$(echo "$git_url" | sed -E 's|.*github\.com[:/]([^/]+)/.*|\1|')
    repo=$(echo "$git_url" | sed -E 's|.*github\.com[:/][^/]+/([^/]+)(\.git)?$|\1|' | sed 's/\.git$//')
    echo "$owner/$repo"
  else
    echo "unknown/unknown"
  fi
}
