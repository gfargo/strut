#!/usr/bin/env bash
# ==================================================
# cmd_ship.sh — Commit, push, and remote rebuild in one command
# ==================================================
# Usage: strut <stack> ship --env <name> [--message <msg>] [--no-commit]
#
# The "edit locally, deploy remotely" workflow in a single command:
#   1. Commit staged changes (or verify clean tree)
#   2. Push to remote
#   3. SSH to target host
#   4. git pull && strut <stack> rebuild --env <name>
# ==================================================

set -euo pipefail

_usage_ship() {
  echo ""
  echo "Usage: strut <stack> ship --env <name> [options]"
  echo ""
  echo "Commit, push, and rebuild on the remote host in one step."
  echo ""
  echo "Options:"
  echo "  --env <name>         Environment (required)"
  echo "  --message <msg>      Commit message (default: 'update <stack>')"
  echo "  -m <msg>             Short form of --message"
  echo "  --no-commit          Skip commit (just push + remote rebuild)"
  echo "  --no-push            Skip push (just remote rebuild)"
  echo "  --no-cache           Pass --no-cache to remote rebuild"
  echo "  --dry-run            Show execution plan without running"
  echo ""
  echo "Examples:"
  echo "  strut hub ship --env prod"
  echo "  strut hub ship --env prod -m 'fix dashboard layout'"
  echo "  strut hub ship --env prod --no-commit"
  echo ""
  echo "What it does:"
  echo "  1. git add -A && git commit -m '<message>'"
  echo "  2. git push origin <branch>"
  echo "  3. ssh <host> 'cd <deploy_dir> && git pull && strut <stack> rebuild --env <name>'"
  echo ""
}

# cmd_ship [options] (reads CMD_*)
cmd_ship() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  # Parse flags
  local commit_msg=""
  local skip_commit=false
  local skip_push=false
  local no_cache=false
  local dry_run="${DRY_RUN:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message|-m) commit_msg="$2"; shift 2 ;;
      --no-commit) skip_commit=true; shift ;;
      --no-push) skip_push=true; shift ;;
      --no-cache) no_cache=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  # Default commit message
  [ -z "$commit_msg" ] && commit_msg="update $stack"

  # Resolve connection info (from env file or topology)
  validate_env_file "$env_file" VPS_HOST
  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"
  local branch="${DEFAULT_BRANCH:-main}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Build remote rebuild command
  local remote_rebuild="strut $stack rebuild --env $env_name"
  [ "$no_cache" = "true" ] && remote_rebuild="$remote_rebuild --no-cache"

  print_banner "Ship"
  log "Stack: $stack | Env: $env_name | Target: $vps_user@$vps_host"
  echo ""

  # ── Dry-run ──────────────────────────────────────────────────────────────
  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan for ship:${NC}"
    if [ "$skip_commit" != "true" ]; then
      run_cmd "Stage and commit" git commit -am "$commit_msg"
    fi
    if [ "$skip_push" != "true" ]; then
      run_cmd "Push to origin/$branch" git push origin "$branch"
    fi
    run_cmd "Pull on remote" ssh $ssh_opts "$vps_user@$vps_host" "cd $deploy_dir && git pull origin $branch"
    run_cmd "Rebuild on remote" ssh $ssh_opts "$vps_user@$vps_host" "cd $deploy_dir && $remote_rebuild"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # ── Step 1: Commit ───────────────────────────────────────────────────────
  if [ "$skip_commit" != "true" ]; then
    log "[1/3] Committing changes..."
    if git diff --quiet && git diff --cached --quiet; then
      log "  Working tree clean — skipping commit"
    else
      git add -A
      git commit -m "$commit_msg" || fail "Commit failed"
      ok "Committed: $commit_msg"
    fi
  else
    log "[1/3] Skipping commit (--no-commit)"
  fi

  # ── Step 2: Push ─────────────────────────────────────────────────────────
  if [ "$skip_push" != "true" ]; then
    log "[2/3] Pushing to origin/$branch..."
    git push origin "$branch" || fail "Push failed"
    ok "Pushed to origin/$branch"
  else
    log "[2/3] Skipping push (--no-push)"
  fi

  # ── Step 3: Remote rebuild ──────────────────────────────────────────────
  log "[3/3] Rebuilding on $vps_host..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    cd '$deploy_dir'
    git pull origin '$branch'
    $remote_rebuild
  " || fail "Remote rebuild failed"

  echo ""
  ok "Shipped! $stack deployed to $vps_host"
}
