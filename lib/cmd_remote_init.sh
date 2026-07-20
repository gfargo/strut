#!/usr/bin/env bash
# ==================================================
# cmd_remote_init.sh — Bootstrap strut on a remote VPS
# ==================================================
# Usage: strut <stack> remote:init --env <name>
#        strut remote:init --host <host> --user <user> [--key <path>] [--port <port>]
#
# Clones the project repository to VPS_DEPLOY_DIR on the remote host,
# verifies strut is executable, and confirms connectivity.
# ==================================================

set -euo pipefail

_usage_remote_init() {
  echo "Usage: strut <stack> remote:init --env <name>"
  echo "       strut remote:init --host <host> --user <user> [options]"
  echo ""
  echo "Bootstrap strut on a remote VPS by cloning the project repository"
  echo "and verifying the installation."
  echo ""
  echo "Options:"
  echo "  --env <name>       Environment file to read VPS connection info from"
  echo "  --host <host>      VPS hostname or IP (overrides VPS_HOST from env)"
  echo "  --user <user>      SSH user (overrides VPS_USER from env)"
  echo "  --key <path>       SSH key path (overrides VPS_SSH_KEY from env)"
  echo "  --port <port>      SSH port (overrides VPS_PORT from env, default: 22)"
  echo "  --repo <url>       Git repository URL (default: detected from local git remote)"
  echo "  --branch <name>    Branch to checkout (default: main)"
  echo "  --deploy-dir <p>   Remote deploy directory (overrides VPS_DEPLOY_DIR)"
  echo "  --dry-run          Show what would be done without executing"
  echo ""
  echo "Examples:"
  echo "  strut my-stack remote:init --env prod"
  echo "  strut remote:init --host compass.local --user gfargo --key ~/.ssh/id_rsa"
  echo ""
  echo "What this does:"
  echo "  1. Verifies SSH connectivity to the remote host"
  echo "  2. Checks if strut is already installed at the deploy directory"
  echo "  3. Clones the project repository (with auth if needed)"
  echo "  4. Makes the strut CLI executable"
  echo "  5. Verifies strut --version works on the remote"
}

# cmd_remote_init [options] (reads CMD_* when available)
cmd_remote_init() {
  local host="" user="" ssh_key="" port="" repo_url="" branch="main" deploy_dir=""
  local dry_run="${DRY_RUN:-false}"

  # Read from CMD_* context if available (stack-scoped invocation)
  local stack="${CMD_STACK:-}"
  local env_file="${CMD_ENV_FILE:-}"

  # Parse command-specific flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host) host="$2"; shift 2 ;;
      --user) user="$2"; shift 2 ;;
      --key) ssh_key="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --repo) repo_url="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --deploy-dir) deploy_dir="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  # run_cmd (used below in the dry-run plan) reads the global DRY_RUN rather
  # than this function's local flag, so keep them in sync — otherwise a
  # caller that reaches --dry-run via this function's own parsing (e.g. the
  # top-level `strut remote:init --host ... --dry-run` form, which bypasses
  # the stack-scoped entrypoint's DRY_RUN export) would print the dry-run
  # banner while actually executing the SSH commands.
  if [ "$dry_run" = "true" ]; then
    DRY_RUN=true
    export DRY_RUN
  fi

  # If env file is available, source it for defaults
  if [ -n "$env_file" ] && [ -f "$env_file" ]; then
    validate_env_file "$env_file"
  fi

  # Resolve connection parameters (CLI flags override env vars)
  host="${host:-${VPS_HOST:-}}"
  user="${user:-${VPS_USER:-ubuntu}}"
  ssh_key="${ssh_key:-${VPS_SSH_KEY:-}}"
  port="${port:-${VPS_PORT:-22}}"
  deploy_dir="${deploy_dir:-$(resolve_deploy_dir)}"
  branch="${branch:-${DEFAULT_BRANCH:-main}}"

  # Validate required params
  if [ -z "$host" ]; then
    fail "VPS_HOST is required. Use --host or set VPS_HOST in your env file."
    return 1
  fi

  # Detect repo URL from local git remote if not specified
  if [ -z "$repo_url" ]; then
    repo_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -z "$repo_url" ]; then
      fail "Could not detect git remote URL. Use --repo <url> to specify."
      return 1
    fi
    log "Detected repository: $repo_url"
  fi

  # Build SSH options
  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$port" -k "$ssh_key" --batch)

  print_banner "Remote Init"
  log "Target: $user@$host:$port"
  log "Deploy dir: $deploy_dir"
  log "Repository: $repo_url"
  log "Branch: $branch"
  echo ""

  # ── Dry-run mode ─────────────────────────────────────────────────────────
  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan for remote:init:${NC}"
    run_cmd "Test SSH connectivity" ssh $ssh_opts "$user@$host" "echo ok"
    run_cmd "Check if deploy dir exists" ssh $ssh_opts "$user@$host" "test -d '$deploy_dir'"
    run_cmd "Clone repository" ssh $ssh_opts "$user@$host" "git clone $repo_url $deploy_dir"
    run_cmd "Checkout branch" ssh $ssh_opts "$user@$host" "cd $deploy_dir && git checkout $branch"
    run_cmd "Make strut executable" ssh $ssh_opts "$user@$host" "chmod +x $deploy_dir/strut"
    run_cmd "Verify strut" ssh $ssh_opts "$user@$host" "cd $deploy_dir && ./strut --version"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # ── Step 1: Test SSH connectivity ────────────────────────────────────────
  log "[1/4] Testing SSH connectivity..."
  if ! ssh $ssh_opts "$user@$host" "echo ok" >/dev/null 2>&1; then
    fail "Cannot connect to $user@$host (port $port). Check host, user, and SSH key."
  fi
  ok "SSH connection successful"

  # ── Step 2: Check if already initialized ─────────────────────────────────
  log "[2/4] Checking remote deploy directory..."
  # shellcheck disable=SC2029
  if ssh $ssh_opts "$user@$host" "test -d '$deploy_dir/.git'"; then
    # Already exists — verify the strut binary actually works before
    # reporting success. A .git checkout with no working strut binary (e.g.
    # cloned by some other means, or left behind by a partial prior run)
    # would otherwise report "already initialized" and send the operator
    # into a release/update loop that fails with an unrelated error later.
    log "Deploy directory already exists at $deploy_dir"

    # Ensure the exec bit is set before checking — mirrors the fresh-clone
    # path below. Harmless no-op if the binary doesn't exist.
    # shellcheck disable=SC2029
    ssh $ssh_opts "$user@$host" "chmod +x '$deploy_dir/strut'" 2>/dev/null || true

    local remote_version
    # shellcheck disable=SC2029
    remote_version=$(ssh $ssh_opts "$user@$host" "cd '$deploy_dir' && ./strut --version 2>/dev/null" || echo "")

    if [ -z "$remote_version" ]; then
      fail "Deploy directory exists at $deploy_dir, but the strut binary is missing or broken (./strut --version failed).
This usually means the repo was cloned some other way and never vendored a working strut executable.
Next step: remove the directory and re-run remote:init for a clean checkout:
  ssh $user@$host \"rm -rf '$deploy_dir'\"
  strut ${stack:-<stack>} remote:init --env ${CMD_ENV_NAME:-prod}"
    fi

    local remote_branch
    # shellcheck disable=SC2029
    remote_branch=$(ssh $ssh_opts "$user@$host" "cd '$deploy_dir' && git rev-parse --abbrev-ref HEAD 2>/dev/null" || echo "unknown")

    ok "strut already initialized on $host"
    echo "  Version: $remote_version"
    echo "  Branch:  $remote_branch"
    echo "  Path:    $deploy_dir"
    echo ""
    echo "To update, run: strut ${stack:-<stack>} update --env ${CMD_ENV_NAME:-prod}"
    return 0
  fi

  # ── Step 3: Clone repository ─────────────────────────────────────────────
  log "[3/4] Cloning repository to $deploy_dir..."

  # Use the existing setup_strut_repo infrastructure from migrate module
  # which handles PAT auth, deploy keys, and SSH access testing
  local gh_pat="${GH_PAT:-}"

  if [ -n "$gh_pat" ]; then
    # GH_PAT available — use it for HTTPS clone with token injection
    local clone_url="$repo_url"
    # Convert SSH URL to HTTPS if needed
    if echo "$clone_url" | grep -q "^git@"; then
      clone_url=$(echo "$clone_url" | sed 's|git@github.com:|https://github.com/|' | sed 's|\.git$||')
    fi
    # Ensure .git suffix for clone
    [[ "$clone_url" == *.git ]] || clone_url="${clone_url}.git"

    # PAT travels over ssh's stdin (never argv) — see remote_ssh_with_pat.
    local clone_script="
      set -e
      git_cred clone \
        --branch '$branch' \
        '$clone_url' '$deploy_dir'
    "
    remote_ssh_with_pat "$ssh_opts" "$user@$host" "$gh_pat" "$clone_script" \
      || fail "Failed to clone repository. Check GH_PAT and repository access."
  else
    # No PAT — delegate to setup_strut_repo which handles interactive auth
    setup_strut_repo "$user" "$host" "$port" "$ssh_key" "$repo_url" "$deploy_dir"

    # Checkout the correct branch
    # shellcheck disable=SC2029
    ssh $ssh_opts "$user@$host" "cd '$deploy_dir' && git checkout '$branch'" 2>/dev/null || true
  fi

  ok "Repository cloned to $deploy_dir"

  # ── Step 4: Verify installation ──────────────────────────────────────────
  log "[4/4] Verifying strut installation..."

  # Make CLI executable
  # shellcheck disable=SC2029
  ssh $ssh_opts "$user@$host" "chmod +x '$deploy_dir/strut'"

  # Verify strut runs
  local remote_version
  # shellcheck disable=SC2029
  remote_version=$(ssh $ssh_opts "$user@$host" "cd '$deploy_dir' && ./strut --version 2>/dev/null" || echo "")

  if [ -z "$remote_version" ]; then
    warn "strut was cloned but --version check failed"
    warn "This may be fine — verify manually with: ssh $user@$host 'cd $deploy_dir && ./strut --version'"
  else
    ok "strut $remote_version running on $host"
  fi

  echo ""
  ok "Remote initialization complete!"
  echo ""
  echo "Next steps:"
  echo "  1. Copy your env file to the VPS:"
  echo "     scp .prod.env $user@$host:$deploy_dir/"
  echo "  2. Deploy your stack:"
  echo "     strut ${stack:-<stack>} release --env ${CMD_ENV_NAME:-prod}"
}
