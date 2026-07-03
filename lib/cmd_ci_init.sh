#!/usr/bin/env bash
# ==================================================
# cmd_ci_init.sh — Bootstrap CI/CD secrets for a stack
# ==================================================
# Usage: strut <stack> ci:init [--provider github|gitlab|manual]
#                              [--repo <owner/repo>] [--dry-run] [--yes]
#
# Discovers which secrets a CI pipeline needs for deploying the stack,
# categorizes them (auto-resolvable, env-sourced, key-based, manual),
# and either prints ready-to-paste commands or pushes them directly.
# ==================================================
# Requires: lib/utils.sh, lib/topology.sh, lib/cmd_ssh_keygen.sh sourced first

set -euo pipefail

_usage_ci_init() {
  echo "Usage: strut <stack> ci:init [options]"
  echo ""
  echo "Bootstrap CI/CD secrets for deploying this stack."
  echo ""
  echo "Options:"
  echo "  --provider <name>   CI provider: github (default), gitlab, manual"
  echo "  --repo <owner/repo> Target repo (default: auto-detect from git remote)"
  echo "  --key-name <label>  Deploy key name (default: ci)"
  echo "  --dry-run           Show what secrets would be set without executing"
  echo "  --yes               Push secrets without confirmation (requires gh/glab CLI)"
  echo ""
  echo "The command discovers secrets from:"
  echo "  • strut.conf topology (host, user, deploy directory)"
  echo "  • Deploy key (~/.ssh/strut_<host>_<key-name>)"
  echo "  • Stack env file (API URLs, project refs, tokens)"
  echo "  • ci_secrets manifest (if present in the stack dir)"
  echo ""
  echo "Secret categories:"
  echo "  ✓ AUTO    — derived from strut.conf/topology"
  echo "  ✓ KEY     — deploy key file (from ssh:keygen)"
  echo "  ✓ ENV     — value from .env file"
  echo "  ? MANUAL  — requires human input (prints instructions)"
  echo ""
  echo "Examples:"
  echo "  strut my-app ci:init                         # Print checklist (manual mode)"
  echo "  strut my-app ci:init --provider github --yes # Push via gh CLI"
  echo "  strut my-app ci:init --dry-run               # Preview only"
  echo ""
}

# ── Secret discovery ─────────────────────────────────────────────────────────

# _ci_detect_provider
# Auto-detect CI provider from project files.
# Returns: github, gitlab, or manual
_ci_detect_provider() {
  local project_root="${PROJECT_ROOT:-$CLI_ROOT}"
  if [ -d "$project_root/.github" ]; then
    echo "github"
  elif [ -f "$project_root/.gitlab-ci.yml" ]; then
    echo "gitlab"
  else
    echo "manual"
  fi
}

# _ci_detect_repo
# Auto-detect repo from git remote.
# Returns: owner/repo or empty string
_ci_detect_repo() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  [ -n "$remote_url" ] || return 0

  # Extract owner/repo from various URL formats
  local repo=""
  if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
    repo="${BASH_REMATCH[1]}"
  elif [[ "$remote_url" =~ gitlab\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
    repo="${BASH_REMATCH[1]}"
  fi
  echo "$repo"
}

# _ci_find_deploy_key <host_alias> <key_name>
# Find existing deploy key for the host.
# Returns: path to private key or empty string
_ci_find_deploy_key() {
  local host_alias="$1"
  local key_name="$2"
  local key_path="$HOME/.ssh/strut_${host_alias}_${key_name}"

  if [ -f "$key_path" ]; then
    echo "$key_path"
    return 0
  fi

  # Try to find any strut key for this host
  local found
  found=$(find "$HOME/.ssh" -maxdepth 1 -name "strut_${host_alias}_*" -not -name "*.pub" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi

  return 1
}

# _ci_discover_secrets <stack> <stack_dir> <env_file> <host_alias> <user> <host> <port> <key_name>
# Discovers and categorizes all CI secrets needed.
# Outputs tab-separated lines: NAME\tCATEGORY\tVALUE\tSOURCE
# Categories: AUTO, KEY, ENV, MANUAL
_ci_discover_secrets() {
  local stack="$1"
  local stack_dir="$2"
  local env_file="$3"
  local host_alias="$4"
  local user="$5"
  local host="$6"
  local port="$7"
  local key_name="$8"

  local deploy_dir; deploy_dir=$(resolve_deploy_dir)

  # ── AUTO secrets (from topology) ─────────────────────────────────────────
  printf '%s\t%s\t%s\t%s\n' "DEPLOY_HOST" "AUTO" "$host" "strut.conf [hosts]"
  printf '%s\t%s\t%s\t%s\n' "DEPLOY_USER" "AUTO" "$user" "strut.conf [hosts]"
  [ "$port" != "22" ] && printf '%s\t%s\t%s\t%s\n' "DEPLOY_PORT" "AUTO" "$port" "strut.conf [hosts]"
  printf '%s\t%s\t%s\t%s\n' "DEPLOY_DIR" "AUTO" "$deploy_dir" "VPS_DEPLOY_DIR or default"
  printf '%s\t%s\t%s\t%s\n' "DEPLOY_STACK" "AUTO" "$stack" "stack name"

  # ── KEY secrets (deploy key) ─────────────────────────────────────────────
  local deploy_key
  if deploy_key=$(_ci_find_deploy_key "$host_alias" "$key_name"); then
    printf '%s\t%s\t%s\t%s\n' "DEPLOY_SSH_KEY" "KEY" "$deploy_key" "$deploy_key"
  else
    printf '%s\t%s\t%s\t%s\n' "DEPLOY_SSH_KEY" "MANUAL" "" "Run: strut $stack ssh:keygen --name $key_name"
  fi

  # ── ENV secrets (from env file) ──────────────────────────────────────────
  # Check for ci_secrets manifest first
  local ci_manifest="$stack_dir/ci_secrets"
  if [ -f "$ci_manifest" ]; then
    while IFS= read -r var; do
      [[ -z "$var" || "$var" =~ ^[[:space:]]*# ]] && continue
      var=$(echo "$var" | tr -d '[:space:]')
      local val=""
      if [ -f "$env_file" ]; then
        val=$(grep "^${var}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)
      fi
      if [ -n "$val" ]; then
        printf '%s\t%s\t%s\t%s\n' "$var" "ENV" "$val" ".env file"
      else
        printf '%s\t%s\t%s\t%s\n' "$var" "MANUAL" "" "Not found in env file"
      fi
    done < "$ci_manifest"
  else
    # Heuristic: look for common CI-relevant vars in the env file
    if [ -f "$env_file" ]; then
      while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        case "$key" in
          *API_URL*|*API_TOKEN*|*ACCESS_TOKEN*|*PROJECT_REF*|*REGISTRY_TOKEN*)
            printf '%s\t%s\t%s\t%s\n' "$key" "ENV" "$val" ".env file"
            ;;
        esac
      done < "$env_file"
    fi
  fi

  # ── MANUAL secrets (common CI needs that we can't auto-resolve) ──────────
  # Only suggest Tailscale if the host looks like a tailnet hostname
  if [[ "$host" == *.ts.net ]] || [[ "$host" == *tailscale* ]]; then
    printf '%s\t%s\t%s\t%s\n' "TS_OAUTH_CLIENT_ID" "MANUAL" "" "https://login.tailscale.com/admin/settings/oauth"
    printf '%s\t%s\t%s\t%s\n' "TS_OAUTH_SECRET" "MANUAL" "" "https://login.tailscale.com/admin/settings/oauth"
  fi
}

# ── Output formatters ────────────────────────────────────────────────────────

# _ci_print_checklist <secrets_data> <provider> <repo>
# Print a human-readable checklist of secrets
_ci_print_checklist() {
  local secrets_data="$1"
  local provider="$2"
  local repo="$3"

  local auto_count=0 key_count=0 env_count=0 manual_count=0

  echo ""
  echo "CI secrets needed:"
  echo ""

  while IFS=$'\t' read -r name category value source; do
    [ -z "$name" ] && continue
    case "$category" in
      AUTO)
        printf '  ✓ %-24s = %s (from %s)\n' "$name" "$value" "$source"
        auto_count=$((auto_count + 1))
        ;;
      KEY)
        printf '  ✓ %-24s ← %s\n' "$name" "$source"
        key_count=$((key_count + 1))
        ;;
      ENV)
        printf '  ✓ %-24s = %s (from %s)\n' "$name" "${value:0:8}..." "$source"
        env_count=$((env_count + 1))
        ;;
      MANUAL)
        if [ -n "$source" ]; then
          printf '  ? %-24s → %s\n' "$name" "$source"
        else
          printf '  ? %-24s (needs manual input)\n' "$name"
        fi
        manual_count=$((manual_count + 1))
        ;;
    esac
  done <<< "$secrets_data"

  echo ""
  log "Summary: $auto_count auto, $key_count key, $env_count env, $manual_count manual"
}

# _ci_print_commands <secrets_data> <provider> <repo>
# Print provider-specific commands to set secrets
_ci_print_commands() {
  local secrets_data="$1"
  local provider="$2"
  local repo="$3"

  echo ""
  case "$provider" in
    github)
      echo "Commands to set GitHub secrets${repo:+ for $repo}:"
      echo ""
      while IFS=$'\t' read -r name category value source; do
        [ -z "$name" ] && continue
        [ "$category" = "MANUAL" ] && continue
        if [ "$category" = "KEY" ] && [ -n "$value" ]; then
          echo "  gh secret set $name < $value${repo:+ -R $repo}"
        elif [ -n "$value" ]; then
          echo "  gh secret set $name --body \"$value\"${repo:+ -R $repo}"
        fi
      done <<< "$secrets_data"
      ;;
    gitlab)
      echo "Commands to set GitLab CI variables${repo:+ for $repo}:"
      echo ""
      while IFS=$'\t' read -r name category value source; do
        [ -z "$name" ] && continue
        [ "$category" = "MANUAL" ] && continue
        if [ "$category" = "KEY" ] && [ -n "$value" ]; then
          echo "  glab variable set $name --value \"\$(cat $value)\"${repo:+ -R $repo}"
        elif [ -n "$value" ]; then
          echo "  glab variable set $name --value \"$value\"${repo:+ -R $repo}"
        fi
      done <<< "$secrets_data"
      ;;
    manual)
      echo "Secrets to configure in your CI provider:"
      echo ""
      while IFS=$'\t' read -r name category value source; do
        [ -z "$name" ] && continue
        [ "$category" = "MANUAL" ] && continue
        if [ "$category" = "KEY" ] && [ -n "$value" ]; then
          echo "  $name = (contents of $value)"
        elif [ -n "$value" ]; then
          echo "  $name = $value"
        fi
      done <<< "$secrets_data"
      ;;
  esac
  echo ""
}

# _ci_push_github <secrets_data> <repo>
# Push secrets directly via gh CLI
_ci_push_github() {
  local secrets_data="$1"
  local repo="$2"

  local pushed=0 skipped=0 failed=0
  local repo_flag=""
  [ -n "$repo" ] && repo_flag="-R $repo"

  while IFS=$'\t' read -r name category value source; do
    [ -z "$name" ] && continue
    [ "$category" = "MANUAL" ] && { skipped=$((skipped + 1)); continue; }

    if [ "$category" = "KEY" ] && [ -n "$value" ]; then
      # shellcheck disable=SC2086
      if gh secret set "$name" < "$value" $repo_flag 2>/dev/null; then
        ok "  $name"
        pushed=$((pushed + 1))
      else
        error "  $name (failed)"
        failed=$((failed + 1))
      fi
    elif [ -n "$value" ]; then
      # shellcheck disable=SC2086
      if echo "$value" | gh secret set "$name" $repo_flag 2>/dev/null; then
        ok "  $name"
        pushed=$((pushed + 1))
      else
        error "  $name (failed)"
        failed=$((failed + 1))
      fi
    else
      skipped=$((skipped + 1))
    fi
  done <<< "$secrets_data"

  echo ""
  log "Pushed: $pushed, Skipped: $skipped (manual), Failed: $failed"
  [ "$failed" -eq 0 ] || return 1
}

# ── Command handler ──────────────────────────────────────────────────────────

cmd_ci_init() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local dry_run="${DRY_RUN:-false}"

  local provider="" repo="" key_name="ci" auto_yes=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)  provider="$2"; shift 2 ;;
      --repo)      repo="$2"; shift 2 ;;
      --key-name)  key_name="$2"; shift 2 ;;
      --dry-run)   dry_run=true; shift ;;
      --yes)       auto_yes=true; shift ;;
      --help|-h)   _usage_ci_init; return 0 ;;
      *)           shift ;;
    esac
  done

  # Auto-detect provider
  if [ -z "$provider" ]; then
    provider=$(_ci_detect_provider)
  fi

  # Validate provider
  case "$provider" in
    github|gitlab|manual) ;;
    *) fail "Unknown CI provider '$provider' — use github, gitlab, or manual"; return 1 ;;
  esac

  # Auto-detect repo
  if [ -z "$repo" ]; then
    repo=$(_ci_detect_repo)
  fi

  # Source env file for VPS connection info
  if [ -f "$env_file" ]; then
    set -a; source "$env_file" 2>/dev/null; set +a
  fi

  # Resolve host (reuse ssh:keygen's resolver)
  if ! _ssh_keygen_resolve_host "$stack"; then
    fail "Cannot resolve target host for '$stack'. Add to [hosts]/[stacks] in strut.conf or set VPS_HOST."
    return 1
  fi
  local user="$_KEYGEN_USER"
  local host="$_KEYGEN_HOST"
  local port="$_KEYGEN_PORT"
  local host_alias="$_KEYGEN_HOST_ALIAS"

  # Resolve stack-level env file for secret values
  local stack_env=""
  stack_env=$(_secrets_resolve_local_env "$stack_dir" "${CMD_ENV_NAME:-prod}" 2>/dev/null) || stack_env="$env_file"

  print_banner "CI Init"
  log "Stack: $stack → Host: $host_alias ($user@$host)"
  log "Provider: $provider${repo:+ | Repo: $repo}"
  log "Deploy key name: $key_name"
  echo ""

  # ── Discover secrets ─────────────────────────────────────────────────────
  local secrets_data
  secrets_data=$(_ci_discover_secrets "$stack" "$stack_dir" "$stack_env" "$host_alias" "$user" "$host" "$port" "$key_name")

  # ── Dry-run ──────────────────────────────────────────────────────────────
  if [ "$dry_run" = "true" ]; then
    _ci_print_checklist "$secrets_data" "$provider" "$repo"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No secrets pushed.${NC}"
    return 0
  fi

  # ── Print checklist ──────────────────────────────────────────────────────
  _ci_print_checklist "$secrets_data" "$provider" "$repo"

  # ── Output commands or push ──────────────────────────────────────────────
  if [ "$provider" = "github" ] && [ "$auto_yes" = "true" ]; then
    # Check gh CLI
    if ! command -v gh &>/dev/null; then
      warn "gh CLI not found — falling back to manual output"
      _ci_print_commands "$secrets_data" "$provider" "$repo"
      return 0
    fi
    if ! gh auth status &>/dev/null 2>&1; then
      warn "gh CLI not authenticated — falling back to manual output"
      _ci_print_commands "$secrets_data" "$provider" "$repo"
      return 0
    fi

    echo ""
    log "Pushing secrets via gh CLI..."
    echo ""
    _ci_push_github "$secrets_data" "$repo"
  elif [ "$provider" = "github" ] && command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    _ci_print_commands "$secrets_data" "$provider" "$repo"
    echo ""
    log "gh CLI is authenticated. Run with --yes to push directly."
  else
    _ci_print_commands "$secrets_data" "$provider" "$repo"
  fi

  # ── Manual items note ────────────────────────────────────────────────────
  local manual_items
  manual_items=$(echo "$secrets_data" | grep $'\tMANUAL\t' || true)
  if [ -n "$manual_items" ]; then
    echo ""
    warn "Some secrets need manual setup:"
    while IFS=$'\t' read -r name category value source; do
      [ -z "$name" ] && continue
      echo "  ? $name → $source"
    done <<< "$manual_items"
  fi
}
