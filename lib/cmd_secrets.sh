#!/usr/bin/env bash
# ==================================================
# cmd_secrets.sh — Push/pull/diff .env secrets to/from VPS
# ==================================================
# Usage: strut <stack> secrets push --env <name>
#        strut <stack> secrets pull --env <name>
#        strut <stack> secrets diff --env <name>
#        strut <stack> secrets validate --env <name>
#
# Securely syncs environment files between local and remote.
# Complements init-secrets (generate) and keys env:* (rotate/validate).
# ==================================================
# Requires: lib/utils.sh, lib/config.sh sourced first

set -euo pipefail

_usage_secrets() {
  echo ""
  echo "Usage: strut <stack> secrets <subcommand> [--env <name>]"
  echo ""
  echo "Manage environment secrets: source, validate, sync, and protect."
  echo ""
  echo "Subcommands:"
  echo "  hydrate    Build local .env from a template, resolving secret references"
  echo "  push       Upload local .env to VPS (SCP, mode 600)"
  echo "  pull       Download .env from VPS to local"
  echo "  diff       Show differences between local and remote .env"
  echo "  validate   Check required_vars are present before push"
  echo "  status     Show the secrets pipeline state for this stack"
  echo "  rotate     Re-hydrate/re-generate, validate, push, and optionally restart"
  echo "  template   Reverse-engineer a .env.template from an existing .env"
  echo "  export     Export .env to docker-secret, k8s-secret, or env-json format"
  echo ""
  echo "Options:"
  echo "  --env <name>   Environment name (default: prod)"
  echo "  --dry-run      Preview without executing"
  echo "  --force        Overwrite existing file without confirmation"
  echo ""
  echo "Typical workflow:"
  echo "  1. strut <stack> init-secrets --env prod       # Generate random secrets"
  echo "     OR  strut <stack> secrets hydrate --env prod # Fetch from a secret manager"
  echo "  2. strut <stack> secrets validate --env prod   # Check for missing/weak values"
  echo "  3. strut <stack> secrets push --env prod       # Upload to VPS"
  echo "  4. strut <stack> secrets lock --env prod       # Encrypt at rest (safe to commit)"
  echo "     ...later..."
  echo "  5. strut <stack> secrets unlock --env prod     # Restore plaintext for editing"
  echo ""
  echo "Lock/Unlock (at-rest encryption):"
  echo "  Backends:    age (preferred), gpg (fallback) — auto-detected"
  echo "  Recipients:  create .strut-recipients with age/SSH public keys (one per line)"
  echo "               if absent, encrypts to self using ~/.ssh/id_ed25519.pub"
  echo "  Identity:    --identity <file> or STRUT_AGE_IDENTITY env var"
  echo "               defaults to ~/.age/key.txt, ~/.ssh/id_ed25519, ~/.ssh/id_rsa"
  echo ""
  echo "Secret references (in a .env template, resolved by 'hydrate'):"
  echo "  KEY=vault://<item>     Vaultwarden/Bitwarden item (via 'bw')"
  echo "  KEY=exec://<command>   Stdout of a command"
  echo "  KEY=file://<path>      Contents of a file (e.g. /run/secrets/x)"
  echo "  KEY=plain-value        Literal — copied as-is"
  echo ""
  echo "  Note: exec:// runs commands with your privileges — only hydrate templates you trust."
  echo ""
  echo "Related commands:"
  echo "  strut <stack> init-secrets   Generate .env from template (random values)"
  echo "  strut <stack> ssh:keygen     Generate a deploy keypair"
  echo "  strut <stack> ci:init        Bootstrap CI/CD secrets"
  echo "  strut <stack> keys env:*     Rotate/manage individual credentials"
  echo ""
  echo "Examples:"
  echo "  strut my-app secrets hydrate --env prod      # template -> .prod.env"
  echo "  strut my-app secrets push --env prod"
  echo "  strut my-app secrets lock --env prod         # .prod.env -> .prod.env.age"
  echo "  strut my-app secrets unlock --env prod       # .prod.env.age -> .prod.env"
  echo "  strut my-app secrets status --env prod"
  echo "  strut my-app secrets diff --env prod"
  echo ""
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# _secrets_resolve_local_env <stack_dir> <env_name>
# Finds the local env file. Checks stack-level first, then project-level.
_secrets_resolve_local_env() {
  local stack_dir="$1"
  local env_name="$2"

  # Stack-level: stacks/<stack>/.<env>.env
  local stack_env="$stack_dir/.${env_name}.env"
  if [ -f "$stack_env" ]; then
    echo "$stack_env"
    return 0
  fi

  # Project-level: .<env>.env
  local project_env="$CLI_ROOT/.${env_name}.env"
  if [ -f "$project_env" ]; then
    echo "$project_env"
    return 0
  fi

  return 1
}

# _secrets_resolve_remote_path <deploy_dir> <env_name>
# Returns the expected remote path for the env file.
_secrets_resolve_remote_path() {
  local deploy_dir="$1"
  local env_name="$2"
  echo "${deploy_dir}/.${env_name}.env"
}

# _secrets_validate_required_vars <local_env_file> <stack_dir>
# Checks that all vars listed in required_vars are present and non-empty.
# Returns 0 if valid, 1 if missing vars.
_secrets_validate_required_vars() {
  local env_file="$1"
  local stack_dir="$2"

  local required_file="$stack_dir/required_vars"
  if [ ! -f "$required_file" ]; then
    return 0  # No required_vars file = nothing to validate
  fi

  # Source env file into subshell to check
  local missing=()
  while IFS= read -r var; do
    [[ -z "$var" || "$var" =~ ^[[:space:]]*# ]] && continue
    var=$(echo "$var" | tr -d '[:space:]')
    local val
    val=$(grep "^${var}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)
    if [ -z "$val" ]; then
      missing+=("$var")
    fi
  done < "$required_file"

  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing required variables (${#missing[@]}):"
    for v in "${missing[@]}"; do
      echo "  • $v"
    done
    return 1
  fi

  return 0
}

# ── Subcommands ───────────────────────────────────────────────────────────────

# _secrets_push (reads CMD_*)
_secrets_push() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local dry_run="${DRY_RUN:-false}"
  local force=false
  local skip_validation=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=true; shift ;;
      --skip-validation) skip_validation=true; shift ;;
      *) shift ;;
    esac
  done

  # Find local env file
  local local_env
  if ! local_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name"); then
    # Check if the env is locked — provide a helpful hint before failing
    local locked_hint=""
    for _ext in age gpg; do
      for _dir in "$stack_dir" "$CLI_ROOT"; do
        if [ -f "$_dir/.${env_name}.env.${_ext}" ]; then
          locked_hint="$_dir/.${env_name}.env.${_ext}"
          break 2
        fi
      done
    done
    if [ -n "$locked_hint" ]; then
      warn "Env file is locked: $locked_hint"
      warn "Run: strut $stack secrets unlock --env $env_name"
    else
      fail "No local env file found for '$env_name'. Expected: $stack_dir/.${env_name}.env or $CLI_ROOT/.${env_name}.env"
    fi
    return 1
  fi

  # Load VPS connection info (from the env file itself or project-level).
  # Preserve dispatcher-resolved connection vars (topology / --host override)
  # so a global VPS_* in the env file can't clobber the intended target. (LA-223)
  local conn_env="$CLI_ROOT/.${env_name}.env"
  [ -f "$conn_env" ] || conn_env="$local_env"
  local _vh="${VPS_HOST:-}" _vu="${VPS_USER:-}" _vp="${VPS_PORT:-}" _vk="${VPS_SSH_KEY:-}" _vd="${VPS_DEPLOY_DIR:-}"
  set -a; source "$conn_env" 2>/dev/null; set +a
  [ -n "$_vh" ] && export VPS_HOST="$_vh"
  [ -n "$_vu" ] && export VPS_USER="$_vu"
  [ -n "$_vp" ] && export VPS_PORT="$_vp"
  [ -n "$_vk" ] && export VPS_SSH_KEY="$_vk"
  [ -n "$_vd" ] && export VPS_DEPLOY_DIR="$_vd"

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_port="${VPS_PORT:-22}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set. Cannot determine target host."

  local remote_path
  remote_path=$(_secrets_resolve_remote_path "$deploy_dir" "$env_name")

  # Validate secrets before pushing (skippable with --skip-validation)
  if [ "$skip_validation" != "true" ]; then
    local _push_val_ok=true
    _secrets_validate_required_vars "$local_env" "$stack_dir" || _push_val_ok=false
    _secrets_check_content "$local_env" || _push_val_ok=false
    if [ "$_push_val_ok" = "false" ]; then
      echo ""
      warn "Push aborted — fix validation issues first."
      warn "Use 'strut $stack init-secrets --env $env_name' or 'secrets hydrate' to populate."
      warn "Pass --skip-validation to bypass (not recommended)."
      return 1
    fi
  else
    warn "WARNING: --skip-validation active — placeholder, weak-secret, and unresolved-ref checks bypassed."
    warn "         Only skip validation if you are certain the env file is correct before deploying."
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  print_banner "Secrets Push"
  log "Stack: $stack | Env: $env_name"
  log "Local: $local_env"
  log "Remote: $vps_user@$vps_host:$remote_path"
  echo ""

  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan:${NC}"
    run_cmd "Upload env file" scp "$local_env" "$vps_user@$vps_host:$remote_path"
    run_cmd "Set permissions 600" ssh "$vps_user@$vps_host" "chmod 600 $remote_path"
    run_cmd "Verify file exists" ssh "$vps_user@$vps_host" "test -f $remote_path && stat $remote_path"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Warn if remote file already exists (unless --force)
  if [ "$force" != "true" ]; then
    # shellcheck disable=SC2029
    if ssh $ssh_opts "$vps_user@$vps_host" "test -f '$remote_path'" 2>/dev/null; then
      warn "Remote env file already exists: $remote_path"
      warn "Use --force to overwrite, or run 'secrets diff' first."
      echo ""

      # Show quick diff hint
      local remote_vars local_vars
      remote_vars=$(ssh $ssh_opts "$vps_user@$vps_host" "grep -c '^[A-Z]' '$remote_path'" 2>/dev/null || echo "?")
      local_vars=$(grep -c '^[A-Z]' "$local_env" 2>/dev/null || echo "?")
      log "Remote has $remote_vars vars, local has $local_vars vars"
      log "Run: strut $stack secrets diff --env $env_name"
      return 1
    fi
  fi

  # Upload
  log "[1/3] Uploading env file..."
  # Use scp with port flag (-P for scp, not -p)
  local scp_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
  [[ -n "$vps_port" && "$vps_port" != "22" ]] && scp_opts="$scp_opts -P $vps_port"
  [[ -n "$vps_ssh_key" ]] && scp_opts="$scp_opts -o IdentitiesOnly=yes -i $vps_ssh_key"
  # Add mux if enabled
  if ssh_mux_enabled 2>/dev/null; then
    local ctl_path
    ctl_path=$(ssh_mux_control_path)
    scp_opts="$scp_opts -o ControlMaster=auto -o ControlPath=$ctl_path -o ControlPersist=60s"
  fi

  # shellcheck disable=SC2086
  scp $scp_opts "$local_env" "$vps_user@$vps_host:$remote_path" || fail "Upload failed"
  ok "Env file uploaded"

  # Set permissions
  log "[2/3] Setting permissions (600)..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "chmod 600 '$remote_path'" || warn "chmod failed"
  ok "Permissions set"

  # Verify
  log "[3/3] Verifying..."
  local remote_size
  # shellcheck disable=SC2029
  remote_size=$(ssh $ssh_opts "$vps_user@$vps_host" "wc -c < '$remote_path'" 2>/dev/null || echo "0")
  local local_size
  local_size=$(wc -c < "$local_env")

  if [ "$remote_size" -gt 0 ]; then
    ok "Verified: $remote_path ($remote_size bytes)"
  else
    warn "Verification failed — file may be empty on remote"
  fi

  echo ""
  ok "Secrets pushed to $vps_user@$vps_host"
}

# _secrets_pull (reads CMD_*)
_secrets_pull() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local dry_run="${DRY_RUN:-false}"
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=true; shift ;;
      *) shift ;;
    esac
  done

  # Load VPS connection info — preserve dispatcher-resolved vars (topology /
  # --host) across the re-source so a global VPS_* can't clobber it. (LA-223)
  local conn_env="$CLI_ROOT/.${env_name}.env"
  if [ -f "$conn_env" ]; then
    local _vh="${VPS_HOST:-}" _vu="${VPS_USER:-}" _vp="${VPS_PORT:-}" _vk="${VPS_SSH_KEY:-}" _vd="${VPS_DEPLOY_DIR:-}"
    set -a; source "$conn_env" 2>/dev/null; set +a
    [ -n "$_vh" ] && export VPS_HOST="$_vh"
    [ -n "$_vu" ] && export VPS_USER="$_vu"
    [ -n "$_vp" ] && export VPS_PORT="$_vp"
    [ -n "$_vk" ] && export VPS_SSH_KEY="$_vk"
    [ -n "$_vd" ] && export VPS_DEPLOY_DIR="$_vd"
  fi

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_port="${VPS_PORT:-22}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set. Cannot determine source host."

  local remote_path
  remote_path=$(_secrets_resolve_remote_path "$deploy_dir" "$env_name")

  # Output path: project-level
  local local_env="$CLI_ROOT/.${env_name}.env"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  print_banner "Secrets Pull"
  log "Stack: $stack | Env: $env_name"
  log "Remote: $vps_user@$vps_host:$remote_path"
  log "Local: $local_env"
  echo ""

  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan:${NC}"
    run_cmd "Download env file" scp "$vps_user@$vps_host:$remote_path" "$local_env"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Check remote file exists
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$vps_user@$vps_host" "test -f '$remote_path'" 2>/dev/null; then
    fail "Remote env file not found: $remote_path"
    return 1
  fi

  # Warn if local file exists
  if [ "$force" != "true" ] && [ -f "$local_env" ]; then
    warn "Local env file already exists: $local_env"
    warn "Use --force to overwrite."
    return 1
  fi

  # Download to temp file first, then atomically rename (prevents partial file on interrupt)
  log "Downloading..."
  local scp_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
  [[ -n "$vps_port" && "$vps_port" != "22" ]] && scp_opts="$scp_opts -P $vps_port"
  [[ -n "$vps_ssh_key" ]] && scp_opts="$scp_opts -o IdentitiesOnly=yes -i $vps_ssh_key"
  if ssh_mux_enabled 2>/dev/null; then
    local ctl_path
    ctl_path=$(ssh_mux_control_path)
    scp_opts="$scp_opts -o ControlMaster=auto -o ControlPath=$ctl_path -o ControlPersist=60s"
  fi

  local tmp_pull
  tmp_pull=$(mktemp "${local_env}.XXXXXX") || fail "Could not create temp file"
  trap 'rm -f "$tmp_pull" 2>/dev/null' RETURN

  # shellcheck disable=SC2086
  scp $scp_opts "$vps_user@$vps_host:$remote_path" "$tmp_pull" || { rm -f "$tmp_pull"; fail "Download failed"; }
  mv "$tmp_pull" "$local_env"
  chmod 600 "$local_env"
  ok "Env file downloaded: $local_env"
}

# _secrets_diff (reads CMD_*)
_secrets_diff() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"

  # Find local env file
  local local_env
  if ! local_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name"); then
    fail "No local env file found for '$env_name'."
    return 1
  fi

  # Load VPS connection info — preserve dispatcher-resolved vars (topology /
  # --host) across the re-source so a global VPS_* can't clobber it. (LA-223)
  local conn_env="$CLI_ROOT/.${env_name}.env"
  if [ -f "$conn_env" ]; then
    local _vh="${VPS_HOST:-}" _vu="${VPS_USER:-}" _vp="${VPS_PORT:-}" _vk="${VPS_SSH_KEY:-}" _vd="${VPS_DEPLOY_DIR:-}"
    set -a; source "$conn_env" 2>/dev/null; set +a
    [ -n "$_vh" ] && export VPS_HOST="$_vh"
    [ -n "$_vu" ] && export VPS_USER="$_vu"
    [ -n "$_vp" ] && export VPS_PORT="$_vp"
    [ -n "$_vk" ] && export VPS_SSH_KEY="$_vk"
    [ -n "$_vd" ] && export VPS_DEPLOY_DIR="$_vd"
  fi

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_port="${VPS_PORT:-22}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"

  [ -n "$vps_host" ] || fail "VPS_HOST not set."

  local remote_path
  remote_path=$(_secrets_resolve_remote_path "$deploy_dir" "$env_name")

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Check remote exists
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$vps_user@$vps_host" "test -f '$remote_path'" 2>/dev/null; then
    warn "Remote env file not found: $remote_path"
    log "Nothing to compare — push first with: strut $stack secrets push --env $env_name"
    return 0
  fi

  # Fetch remote to tmp — ensure cleanup even on failure (security: secrets on disk)
  local tmp_remote
  tmp_remote=$(mktemp "${TMPDIR:-/tmp}/strut-secrets-diff-XXXXXX") || { fail "Could not create temp file"; return 1; }
  trap 'rm -f "$tmp_remote" 2>/dev/null' RETURN
  local scp_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
  [[ -n "$vps_port" && "$vps_port" != "22" ]] && scp_opts="$scp_opts -P $vps_port"
  [[ -n "$vps_ssh_key" ]] && scp_opts="$scp_opts -o IdentitiesOnly=yes -i $vps_ssh_key"
  if ssh_mux_enabled 2>/dev/null; then
    local ctl_path
    ctl_path=$(ssh_mux_control_path)
    scp_opts="$scp_opts -o ControlMaster=auto -o ControlPath=$ctl_path -o ControlPersist=60s"
  fi

  # shellcheck disable=SC2086
  scp $scp_opts "$vps_user@$vps_host:$remote_path" "$tmp_remote" 2>/dev/null || {
    fail "Could not fetch remote env file"
    return 1
  }

  # Compare keys (not values — don't leak secrets)
  echo ""
  echo "Comparing .${env_name}.env: local vs remote"
  echo "─────────────────────────────────────────────"
  echo ""

  local local_keys remote_keys
  local_keys=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$local_env" | cut -d= -f1 | sort)
  remote_keys=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$tmp_remote" | cut -d= -f1 | sort)

  local only_local only_remote changed_count=0
  only_local=$(comm -23 <(echo "$local_keys") <(echo "$remote_keys"))
  only_remote=$(comm -13 <(echo "$local_keys") <(echo "$remote_keys"))

  # Check for value differences (show key, not value)
  local common_keys
  common_keys=$(comm -12 <(echo "$local_keys") <(echo "$remote_keys"))
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    local lval rval
    lval=$(grep "^${key}=" "$local_env" | head -1 | cut -d= -f2-)
    rval=$(grep "^${key}=" "$tmp_remote" | head -1 | cut -d= -f2-)
    if [ "$lval" != "$rval" ]; then
      changed_count=$((changed_count + 1))
      if [ $changed_count -eq 1 ]; then
        echo -e "${YELLOW}Changed (value differs):${NC}"
      fi
      echo "  ~ $key"
    fi
  done <<< "$common_keys"

  if [ -n "$only_local" ]; then
    [ $changed_count -gt 0 ] && echo ""
    echo -e "${GREEN}Only in local:${NC}"
    while IFS= read -r key; do
      [ -n "$key" ] && echo "  + $key"
    done <<< "$only_local"
  fi

  if [ -n "$only_remote" ]; then
    echo ""
    echo -e "${RED}Only on remote:${NC}"
    while IFS= read -r key; do
      [ -n "$key" ] && echo "  - $key"
    done <<< "$only_remote"
  fi

  if [ $changed_count -eq 0 ] && [ -z "$only_local" ] && [ -z "$only_remote" ]; then
    ok "Local and remote are in sync ($(echo "$local_keys" | wc -l | tr -d ' ') vars)"
  else
    echo ""
    local total_diffs=$(( changed_count + $(echo "$only_local" | grep -c . || true) + $(echo "$only_remote" | grep -c . || true) ))
    log "$total_diffs difference(s) found"
  fi

  rm -f "$tmp_remote"
}

# _secrets_check_content <env_file>
# Checks env file values for unresolved provider references, placeholder values,
# and weak secrets in password-like keys.
# Returns 0 if all OK, 1 if issues found.
_secrets_check_content() {
  local env_file="$1"
  local issues=()

  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    # Strip surrounding single or double quotes (common .env quoting styles)
    [[ "$val" == \"*\" ]] && val="${val:1:${#val}-2}"
    [[ "$val" == \'*\' ]] && val="${val:1:${#val}-2}"

    # Unresolved provider references (should be resolved by `secrets hydrate` first)
    case "$val" in
      vault://*|exec://*|file://*)
        issues+=("$key: unresolved provider reference (${val%%://*}://…)")
        continue
        ;;
    esac

    # Placeholder patterns (mirrors _secrets_is_placeholder in cmd_init_secrets.sh)
    local is_ph=false
    case "$val" in
      ''|change-me*|changeme*|CHANGEME*|Change-Me*) is_ph=true ;;
      your.*|your-*|YOUR_*|YOUR-*) is_ph=true ;;
      xxxx*|XXXX*|xxx*|XXX*) is_ph=true ;;
      ghp_xxx*) is_ph=true ;;
      replace-*|REPLACE_*|replace_*) is_ph=true ;;
      todo*|TODO*|fixme*|FIXME*) is_ph=true ;;
      example*|EXAMPLE*) is_ph=true ;;
      placeholder*|PLACEHOLDER*) is_ph=true ;;
    esac
    if $is_ph; then
      issues+=("$key: placeholder value")
      continue
    fi

    # Weak secrets in password/secret/token-like keys
    local key_lower
    key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    case "$key_lower" in
      *password*|*passwd*|*secret*|*token*)
        local val_lower
        val_lower=$(echo "$val" | tr '[:upper:]' '[:lower:]')
        case "$val_lower" in
          password|password1|changeme|change-me|secret|secret123|admin|test|12345*|qwerty|letmein)
            issues+=("$key: weak/known-bad value")
            ;;
        esac
        ;;
    esac
  done < "$env_file"

  if [ ${#issues[@]} -gt 0 ]; then
    error "Content issues found (${#issues[@]}):"
    for issue in "${issues[@]}"; do
      echo "  • $issue"
    done
    return 1
  fi

  return 0
}

# _secrets_validate (reads CMD_*)
_secrets_validate() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"

  # Find local env file
  local local_env
  if ! local_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name"); then
    fail "No local env file found for '$env_name'."
    return 1
  fi

  log "Validating: $local_env"

  local fail_count=0

  # 1. Required vars presence
  _secrets_validate_required_vars "$local_env" "$stack_dir" || fail_count=$((fail_count + 1))

  # 2. Content quality: placeholders, weak secrets, unresolved references
  _secrets_check_content "$local_env" || fail_count=$((fail_count + 1))

  if [ "$fail_count" -gt 0 ]; then
    return 1
  fi

  local var_count
  var_count=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$local_env" 2>/dev/null || echo "0")
  ok "Validation passed ($var_count vars, required present, no placeholders or weak values)"
}

# _secrets_hydrate (reads CMD_*)
# Materialise the local .<env>.env from a template, resolving any
# <provider>://<ref> references through the configured secret source(s).
# Literal values pass through unchanged. Looks up the template stack-level
# first, then project-level, preferring an env-specific name over .env.template.
_secrets_hydrate() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local dry_run="${DRY_RUN:-false}"
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=true; shift ;;
      *) shift ;;
    esac
  done

  # Resolve the template.
  local template="" cand
  for cand in \
    "$stack_dir/.${env_name}.env.template" \
    "$CLI_ROOT/.${env_name}.env.template" \
    "$stack_dir/.env.template" \
    "$CLI_ROOT/.env.template"; do
    if [ -f "$cand" ]; then template="$cand"; break; fi
  done
  if [ -z "$template" ]; then
    fail "No env template found for '$env_name' (looked for stacks/$stack/.${env_name}.env.template or .env.template)"
    return 1
  fi

  # Output is written next to the template, matching the stack-first then
  # project-level search order that _secrets_resolve_local_env (and therefore
  # `secrets push`) uses to find it.
  local out_file
  out_file="$(dirname "$template")/.${env_name}.env"

  print_banner "Secrets Hydrate"
  log "Stack: $stack | Env: $env_name"
  log "Template: $template"
  log "Output: $out_file"
  echo ""

  # Pass 1 — scan the template. Collect the referenced provider schemes and,
  # for --dry-run, report each mapping and return before touching credentials
  # or disk (preview must work without unlocking the providers).
  local schemes_seen=() value scheme key ref_count=0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    if scheme=$(secrets_reference_scheme "$value"); then
      ref_count=$((ref_count + 1))
      [ "$dry_run" = "true" ] && log "  $key  <-  ${scheme}://$(secrets_reference_target "$value")"
      case " ${schemes_seen[*]-} " in
        *" $scheme "*) ;;
        *) schemes_seen+=("$scheme") ;;
      esac
    fi
  done < "$template"

  if [ "$dry_run" = "true" ]; then
    echo ""
    log "[DRY-RUN] $ref_count reference(s) would be resolved; literals copied as-is."
    echo -e "${YELLOW}[DRY-RUN] No file written.${NC}"
    return 0
  fi

  if [ -f "$out_file" ] && [ "$force" != "true" ]; then
    warn "Output already exists: $out_file"
    warn "Use --force to overwrite."
    return 1
  fi

  # Pre-flight every referenced provider before writing anything, so a missing
  # tool or session aborts with no half-written secret file.
  local s
  for s in ${schemes_seen[@]+"${schemes_seen[@]}"}; do
    secrets_provider_available "$s" || return 1
  done

  # Pass 2 — resolve into a 600-mode temp file in the destination directory,
  # then rename into place (atomic, same filesystem, never transits /tmp).
  local resolved_count=0 literal_count=0 rv
  local tmp_out
  tmp_out=$(mktemp "$(dirname "$out_file")/.hydrate.XXXXXX") || { fail "Could not create temp file"; return 1; }
  chmod 600 "$tmp_out"
  trap 'rm -f "$tmp_out"' RETURN
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$line" >> "$tmp_out"
      continue
    fi
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
      if scheme=$(secrets_reference_scheme "$value"); then
        if ! rv=$(secrets_resolve_reference "$value"); then
          fail "Failed to resolve $key from ${scheme}://$(secrets_reference_target "$value")"
          return 1
        fi
        # .env values are single-line (docker compose env_file can't represent
        # a newline); a multi-line secret means the wrong target — fail loudly
        # rather than emit a corrupt file. Mount multi-line secrets as files.
        if [[ "$rv" == *$'\n'* ]]; then
          fail "$key resolved to a multi-line value, which a .env file can't hold — mount it as a file (e.g. a Docker/compose secret) instead"
          return 1
        fi
        printf '%s=%s\n' "$key" "$rv" >> "$tmp_out"
        resolved_count=$((resolved_count + 1))
      else
        printf '%s\n' "$line" >> "$tmp_out"
        literal_count=$((literal_count + 1))
      fi
    else
      printf '%s\n' "$line" >> "$tmp_out"
    fi
  done < "$template"

  mv "$tmp_out" "$out_file"
  trap - RETURN
  chmod 600 "$out_file"
  echo ""
  ok "Hydrated $out_file ($resolved_count resolved, $literal_count literal)"

  # Post-hydration: warn if any required_vars entries are unset in the output
  local rv_file="$stack_dir/required_vars"
  if [ -f "$rv_file" ]; then
    local missing_rv=()
    while IFS= read -r var || [ -n "$var" ]; do
      [[ -z "$var" || "$var" =~ ^[[:space:]]*# ]] && continue
      var=$(echo "$var" | tr -d '[:space:]')
      local rv_val
      rv_val=$(grep "^${var}=" "$out_file" 2>/dev/null | head -1 | cut -d= -f2-)
      [ -z "$rv_val" ] && missing_rv+=("$var")
    done < "$rv_file"
    if [ ${#missing_rv[@]} -gt 0 ]; then
      warn "Post-hydration: ${#missing_rv[@]} required var(s) not set in output:"
      for v in "${missing_rv[@]}"; do
        echo "  • $v"
      done
      warn "Run 'strut $stack secrets validate --env $env_name' before push."
    fi
  fi
}

# _secrets_status (reads CMD_*)
# Show the state of the secrets pipeline for the current stack.
_secrets_status() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"

  print_banner "Secrets Status: $stack ($env_name)"

  # ── Local env ────────────────────────────────────────────────────────────
  local local_env
  if local_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name"); then
    local var_count modified_ago perms
    var_count=$(grep -c "^[A-Za-z_]" "$local_env" 2>/dev/null || echo 0)
    perms=$(stat -c '%a' "$local_env" 2>/dev/null || stat -f '%OLp' "$local_env" 2>/dev/null || echo "?")

    # Calculate time since last modification
    local mod_ts now_ts diff_secs
    mod_ts=$(stat -c '%Y' "$local_env" 2>/dev/null || stat -f '%m' "$local_env" 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    diff_secs=$((now_ts - mod_ts))
    if [ "$diff_secs" -lt 60 ]; then
      modified_ago="just now"
    elif [ "$diff_secs" -lt 3600 ]; then
      modified_ago="$((diff_secs / 60))m ago"
    elif [ "$diff_secs" -lt 86400 ]; then
      modified_ago="$((diff_secs / 3600))h ago"
    else
      modified_ago="$((diff_secs / 86400))d ago"
    fi

    local location_label
    if [[ "$local_env" == "$stack_dir"* ]]; then
      location_label="stack-level"
    else
      location_label="project-level"
    fi

    echo "  Local env:   $local_env ($location_label)"
    echo "               $var_count vars, mode $perms, modified $modified_ago"
  else
    echo "  Local env:   (not found)"
    echo "               Expected: $stack_dir/.$env_name.env or $CLI_ROOT/.$env_name.env"
  fi

  # ── Template ─────────────────────────────────────────────────────────────
  local template="" cand
  for cand in \
    "$stack_dir/.${env_name}.env.template" \
    "$CLI_ROOT/.${env_name}.env.template" \
    "$stack_dir/.env.template" \
    "$CLI_ROOT/.env.template"; do
    if [ -f "$cand" ]; then template="$cand"; break; fi
  done

  if [ -n "$template" ]; then
    local ref_count=0 literal_count=0 line key value scheme
    while IFS= read -r line || [ -n "$line" ]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        value="${BASH_REMATCH[2]}"
        if secrets_reference_scheme "$value" >/dev/null 2>&1; then
          ref_count=$((ref_count + 1))
        else
          literal_count=$((literal_count + 1))
        fi
      fi
    done < "$template"
    echo "  Template:    $template"
    echo "               $ref_count references, $literal_count literals"
  else
    echo "  Template:    (none found)"
  fi

  # ── Remote env ───────────────────────────────────────────────────────────
  # Source connection info
  local conn_env="$CLI_ROOT/.${env_name}.env"
  if [ -f "$conn_env" ]; then
    set -a; source "$conn_env" 2>/dev/null; set +a
  fi
  if [ -n "$local_env" ] && [ -f "$local_env" ] && [ "$local_env" != "$conn_env" ]; then
    set -a; source "$local_env" 2>/dev/null; set +a
  fi

  local vps_host="${VPS_HOST:-}"
  if [ -n "$vps_host" ]; then
    local vps_user="${VPS_USER:-ubuntu}"
    local vps_port="${VPS_PORT:-22}"
    local vps_ssh_key="${VPS_SSH_KEY:-}"
    local deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"
    local remote_path
    remote_path=$(_secrets_resolve_remote_path "$deploy_dir" "$env_name")

    local ssh_opts
    ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch -t 5)

    local remote_var_count
    # shellcheck disable=SC2029
    remote_var_count=$(ssh $ssh_opts "$vps_user@$vps_host" "grep -c '^[A-Za-z_]' '$remote_path' 2>/dev/null" 2>/dev/null || echo "")

    if [ -n "$remote_var_count" ]; then
      echo "  Remote env:  $vps_user@$vps_host:$remote_path"
      echo "               $remote_var_count vars"

      # Quick sync check (compare var counts as a rough indicator)
      if [ -n "$local_env" ] && [ -f "$local_env" ]; then
        local local_count
        local_count=$(grep -c "^[A-Za-z_]" "$local_env" 2>/dev/null || echo 0)
        if [ "$local_count" = "$remote_var_count" ]; then
          echo "  Sync:        ✓ var counts match ($local_count)"
        else
          echo "  Sync:        ⚠ local has $local_count vars, remote has $remote_var_count"
          echo "               Run 'strut $stack secrets diff --env $env_name' for details"
        fi
      fi
    else
      echo "  Remote env:  $vps_user@$vps_host:$remote_path (unreachable or not found)"
    fi
  else
    echo "  Remote env:  (no VPS_HOST configured)"
  fi

  # ── Required vars ────────────────────────────────────────────────────────
  local required_file="$stack_dir/required_vars"
  if [ -f "$required_file" ]; then
    local total_required=0 present=0 missing_vars=()
    while IFS= read -r var; do
      [[ -z "$var" || "$var" =~ ^[[:space:]]*# ]] && continue
      var=$(echo "$var" | tr -d '[:space:]')
      total_required=$((total_required + 1))
      if [ -n "$local_env" ] && [ -f "$local_env" ]; then
        local val
        val=$(grep "^${var}=" "$local_env" 2>/dev/null | head -1 | cut -d= -f2-)
        if [ -n "$val" ]; then
          present=$((present + 1))
        else
          missing_vars+=("$var")
        fi
      fi
    done < "$required_file"

    if [ ${#missing_vars[@]} -eq 0 ]; then
      echo "  Required:    $present/$total_required present ✓"
    else
      echo "  Required:    $present/$total_required present ✗"
      echo "               Missing: ${missing_vars[*]}"
    fi
  else
    echo "  Required:    (no required_vars file)"
  fi

  # ── Deploy key ───────────────────────────────────────────────────────────
  local host_alias=""
  topology_load 2>/dev/null || true
  if topology_has_host "$stack" 2>/dev/null; then
    host_alias="${_TOPO_STACK_HOST[$stack]:-}"
  elif [ -n "$vps_host" ]; then
    host_alias="$vps_host"
  fi

  if [ -n "$host_alias" ]; then
    local deploy_keys
    deploy_keys=$(find "$HOME/.ssh" -maxdepth 1 -name "strut_${host_alias}_*" -not -name "*.pub" 2>/dev/null || true)
    if [ -n "$deploy_keys" ]; then
      local key_count
      key_count=$(echo "$deploy_keys" | wc -l | tr -d ' ')
      echo "  Deploy keys: $key_count found for $host_alias"
    else
      echo "  Deploy keys: none (run 'strut $stack ssh:keygen --name ci' to generate)"
    fi
  fi

  echo ""
}

# _secrets_rotate (reads CMD_*)
# Re-hydrate or re-generate secrets, validate, push to VPS, and optionally restart containers.
_secrets_rotate() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local dry_run="${DRY_RUN:-false}"
  local restart=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --restart)  restart=true; shift ;;
      --dry-run)  dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  print_banner "Secrets Rotate"
  log "Stack: $stack | Env: $env_name"
  echo ""

  # Locate template to determine rotation strategy
  local template="" cand
  for cand in \
    "$stack_dir/.${env_name}.env.template" \
    "$CLI_ROOT/.${env_name}.env.template" \
    "$stack_dir/.env.template" \
    "$CLI_ROOT/.env.template"; do
    if [ -f "$cand" ]; then template="$cand"; break; fi
  done

  # Step 1: re-hydrate or re-generate
  local step_label="[1/4]"
  if [ -n "$template" ]; then
    # Scan for provider references
    local has_refs=false
    local _line _value
    while IFS= read -r _line || [ -n "$_line" ]; do
      [[ -z "$_line" || "$_line" =~ ^[[:space:]]*# ]] && continue
      [[ "$_line" =~ ^[A-Za-z_][A-Za-z0-9_]*=(.*)$ ]] || continue
      _value="${BASH_REMATCH[1]}"
      if secrets_reference_scheme "$_value" >/dev/null 2>&1; then
        has_refs=true
        break
      fi
    done < "$template"

    if [ "$has_refs" = "true" ]; then
      log "$step_label Hydrating secrets from provider references..."
      if [ "$dry_run" = "true" ]; then
        log "[DRY-RUN] Would run: secrets hydrate --force"
      else
        _secrets_hydrate --force
      fi
    else
      log "$step_label Re-generating secrets from template..."
      if [ "$dry_run" = "true" ]; then
        log "[DRY-RUN] Would run: init-secrets --force"
      else
        cmd_init_secrets --force
      fi
    fi
  else
    log "$step_label No template found — skipping re-generation"
    log "          Create a .env.template to enable automated secret rotation."
  fi

  # Step 2: validate
  log "[2/4] Validating secrets..."
  if [ "$dry_run" = "true" ]; then
    log "[DRY-RUN] Would run: secrets validate"
  else
    _secrets_validate || return 1
  fi

  # Step 3: push
  log "[3/4] Pushing secrets to VPS..."
  if [ "$dry_run" = "true" ]; then
    log "[DRY-RUN] Would run: secrets push --force"
  else
    _secrets_push --force || return 1
  fi

  # Step 4: optional container restart
  if [ "$restart" = "true" ]; then
    log "[4/4] Restarting containers on VPS..."

    # Load VPS connection info
    local conn_env="$CLI_ROOT/.${env_name}.env"
    [ -f "$conn_env" ] || conn_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name" 2>/dev/null || echo "")
    if [ -n "$conn_env" ] && [ -f "$conn_env" ]; then
      local _vh="${VPS_HOST:-}" _vu="${VPS_USER:-}" _vp="${VPS_PORT:-}" _vk="${VPS_SSH_KEY:-}" _vd="${VPS_DEPLOY_DIR:-}"
      set -a; source "$conn_env" 2>/dev/null; set +a
      [ -n "$_vh" ] && export VPS_HOST="$_vh"
      [ -n "$_vu" ] && export VPS_USER="$_vu"
      [ -n "$_vp" ] && export VPS_PORT="$_vp"
      [ -n "$_vk" ] && export VPS_SSH_KEY="$_vk"
      [ -n "$_vd" ] && export VPS_DEPLOY_DIR="$_vd"
    fi

    local vps_host="${VPS_HOST:-}"
    local vps_user="${VPS_USER:-ubuntu}"
    local vps_port="${VPS_PORT:-22}"
    local vps_ssh_key="${VPS_SSH_KEY:-}"
    local deploy_dir="${VPS_DEPLOY_DIR:-/home/$vps_user/strut}"

    [ -n "$vps_host" ] || { warn "VPS_HOST not set — skipping container restart"; return 0; }

    local ssh_opts
    ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

    if [ "$dry_run" = "true" ]; then
      log "[DRY-RUN] Would run: ssh ... docker compose -p $stack restart"
    else
      # shellcheck disable=SC2029
      if ssh $ssh_opts "$vps_user@$vps_host" \
        "cd '$deploy_dir' && docker compose -p '$stack' restart"; then
        ok "Containers restarted"
      else
        warn "Container restart failed"
        return 1
      fi
    fi
  else
    log "[4/4] Skipping restart (use --restart to restart containers after push)"
  fi

  echo ""
  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
  else
    ok "Secrets rotated for $stack ($env_name)"
  fi
}

# _secrets_template (reads CMD_*)
# Reverse-engineer a .env.template from an existing .env file.
_secrets_template() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local dry_run="${DRY_RUN:-false}"
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)    force=true; shift ;;
      --dry-run)  dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  # Find existing env file to read
  local local_env
  if ! local_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name"); then
    fail "No local env file found for '$env_name'. Expected: $stack_dir/.${env_name}.env or $CLI_ROOT/.${env_name}.env"
    return 1
  fi

  local out_file="$stack_dir/.env.template"

  print_banner "Secrets Template"
  log "Stack: $stack | Env: $env_name"
  log "Source: $local_env"
  log "Output: $out_file"
  echo ""

  if [ -f "$out_file" ] && [ "$force" != "true" ] && [ "$dry_run" != "true" ]; then
    warn "Template already exists: $out_file"
    warn "Use --force to overwrite."
    return 1
  fi

  # Helper: detect if a value looks like a generated secret (not a human value)
  _is_generated_secret() {
    local key="$1" val="$2"
    # Long hex string (≥32 chars, only hex)
    if [[ ${#val} -ge 32 ]] && [[ "$val" =~ ^[0-9a-f]+$ ]]; then
      return 0
    fi
    # Long base64-ish string (≥32 chars)
    if [[ ${#val} -ge 32 ]] && [[ "$val" =~ ^[A-Za-z0-9+/]+=*$ ]]; then
      return 0
    fi
    # Key name strongly implies a secret
    local key_lower
    key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    case "$key_lower" in
      *secret*|*password*|*passwd*|*salt*|*jwt*|*encryption*)
        return 0 ;;
    esac
    return 1
  }

  # Helper: detect if a value looks like a structured literal to keep as-is
  _is_literal_value() {
    local val="$1"
    # URLs
    [[ "$val" =~ ^https?:// ]] && return 0
    # DB connection strings
    [[ "$val" =~ ^(postgresql|mysql|redis|mongodb):// ]] && return 0
    # IP addresses
    [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]] && return 0
    # Port numbers or pure integers
    [[ "$val" =~ ^[0-9]+$ ]] && return 0
    # Booleans / common config strings
    case "$val" in
      true|false|yes|no|on|off|enabled|disabled) return 0 ;;
    esac
    return 1
  }

  # Helper: suggest generation hint for key
  _suggest_hint() {
    local key="$1" val="$2"
    local key_lower
    key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    # Infer byte length from value length (hex: len/2 bytes)
    if [[ "$val" =~ ^[0-9a-f]+$ ]] && [[ ${#val} -ge 32 ]]; then
      echo "# Generate with: openssl rand -hex $(( ${#val} / 2 ))"
      return
    fi
    if [[ "$val" =~ ^[A-Za-z0-9+/]+=*$ ]] && [[ ${#val} -ge 32 ]]; then
      echo "# Generate with: openssl rand -base64 32"
      return
    fi
    case "$key_lower" in
      *secret*|*jwt*)     echo "# Generate with: openssl rand -hex 32" ;;
      *password*|*passwd*) echo "# Generate with: openssl rand -hex 16" ;;
      *salt*)             echo "# Generate with: openssl rand -hex 16" ;;
      *key*|*token*)      echo "# Generate with: openssl rand -hex 24" ;;
      *encryption*)       echo "# Generate with: openssl rand -hex 32" ;;
      *)                  echo "" ;;
    esac
  }

  # Process the env file and build the template
  local generated_count=0 literal_count=0 placeholder_count=0
  local output_lines=()

  while IFS= read -r line || [ -n "$line" ]; do
    # Pass through comments and blank lines
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
      output_lines+=("$line")
      continue
    fi

    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"

      if _is_literal_value "$val"; then
        # Keep literal values as-is
        output_lines+=("${key}=${val}")
        literal_count=$((literal_count + 1))
      elif _is_generated_secret "$key" "$val"; then
        # Replace with placeholder + generation hint
        local hint
        hint=$(_suggest_hint "$key" "$val")
        [ -n "$hint" ] && output_lines+=("$hint")
        output_lines+=("${key}=change-me")
        generated_count=$((generated_count + 1))
      else
        local key_lower
        key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')
        case "$key_lower" in
          *token*|*api_key*|*apikey*|*access_key*)
            output_lines+=("${key}=change-me")
            placeholder_count=$((placeholder_count + 1))
            ;;
          *)
            # Non-secret: keep as literal reference
            output_lines+=("${key}=${val}")
            literal_count=$((literal_count + 1))
            ;;
        esac
      fi
    else
      output_lines+=("$line")
    fi
  done < "$local_env"

  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Generated template contents:${NC}"
    echo "─────────────────────────────────────────"
    local l
    for l in "${output_lines[@]}"; do echo "$l"; done
    echo "─────────────────────────────────────────"
    echo ""
    log "Would write: $out_file"
    log "  $generated_count var(s) → change-me (generated secrets)"
    log "  $placeholder_count var(s) → change-me (API keys / tokens)"
    log "  $literal_count var(s) → kept as literals"
    echo -e "${YELLOW}[DRY-RUN] No file written.${NC}"
    return 0
  fi

  # Write output file
  local tmp_out
  tmp_out=$(mktemp "$(dirname "$out_file")/.template.XXXXXX") || { fail "Could not create temp file"; return 1; }
  trap 'rm -f "$tmp_out"' RETURN
  local l
  for l in "${output_lines[@]}"; do printf '%s\n' "$l"; done > "$tmp_out"
  mv "$tmp_out" "$out_file"
  trap - RETURN

  ok "Template written: $out_file"
  echo ""
  log "$generated_count var(s) → change-me (generated secrets)"
  log "$placeholder_count var(s) → change-me (API keys / tokens)"
  log "$literal_count var(s) → kept as literals"
  echo ""
  log "Next: edit $out_file to add vault:// or exec:// references, then:"
  log "  strut $stack secrets hydrate --env $env_name"
}

# _secrets_export (reads CMD_*)
# Export the local .env to another format: docker-secret, k8s-secret, or env-json.
_secrets_export() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local format=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          error "--format requires a value. Choose: docker-secret, k8s-secret, env-json"
          return 1
        fi
        format="$2"; shift 2
        ;;
      --format=*) format="${1#--format=}"; shift ;;
      *) shift ;;
    esac
  done

  if [ -z "$format" ]; then
    error "Missing --format. Choose: docker-secret, k8s-secret, env-json"
    return 1
  fi

  case "$format" in
    docker-secret|k8s-secret|env-json) ;;
    *)
      error "Unknown format '$format'. Choose: docker-secret, k8s-secret, env-json"
      return 1
      ;;
  esac

  # Find local env file
  local local_env
  if ! local_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name"); then
    fail "No local env file found for '$env_name'. Expected: $stack_dir/.${env_name}.env or $CLI_ROOT/.${env_name}.env"
    return 1
  fi

  # Collect key=value pairs (skip comments / blanks)
  local keys=() vals=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    keys+=("${BASH_REMATCH[1]}")
    vals+=("${BASH_REMATCH[2]}")
  done < "$local_env"

  local count=${#keys[@]}
  [ "$count" -eq 0 ] && { warn "No variables found in $local_env"; return 1; }

  case "$format" in
    docker-secret)
      echo "# Docker Swarm: create secrets from $local_env ($env_name)"
      echo "# Run each line or adapt for docker-compose.yml secrets section."
      echo ""
      local i
      for i in "${!keys[@]}"; do
        local k="${keys[$i]}" v="${vals[$i]}"
        local secret_name v_safe
        secret_name=$(echo "${stack}_${k}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        # Use %q so values containing single quotes (or other special chars) are safe
        printf -v v_safe '%q' "$v"
        printf "printf '%%s' %s | docker secret create %s -\n" "$v_safe" "$secret_name"
      done
      echo ""
      echo "# docker-compose.yml secrets section:"
      echo "# secrets:"
      for i in "${!keys[@]}"; do
        local k="${keys[$i]}"
        local secret_name
        secret_name=$(echo "${stack}_${k}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        echo "#   ${k,,}:"
        echo "#     external: true"
        echo "#     name: $secret_name"
      done
      ;;

    k8s-secret)
      local secret_name
      secret_name=$(echo "$stack-$env_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
      echo "# Kubernetes Secret manifest for $stack ($env_name)"
      echo "# Apply with: kubectl apply -f -"
      echo "---"
      echo "apiVersion: v1"
      echo "kind: Secret"
      echo "metadata:"
      echo "  name: $secret_name"
      echo "type: Opaque"
      echo "data:"
      local i
      for i in "${!keys[@]}"; do
        local k="${keys[$i]}" v="${vals[$i]}"
        local encoded
        encoded=$(printf '%s' "$v" | base64 | tr -d '\n')
        printf "  %s: %s\n" "$k" "$encoded"
      done
      ;;

    env-json)
      echo "{"
      local i last=$((count - 1))
      for i in "${!keys[@]}"; do
        local k="${keys[$i]}" v="${vals[$i]}"
        # Escape backslashes and double quotes in values
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        if [ "$i" -lt "$last" ]; then
          printf '  "%s": "%s",\n' "$k" "$v"
        else
          printf '  "%s": "%s"\n' "$k" "$v"
        fi
      done
      echo "}"
      ;;
  esac
}

# ── Lock / Unlock ─────────────────────────────────────────────────────────────

# _secrets_detect_backend — print "age" or "gpg"; return 1 if neither available
_secrets_detect_backend() {
  if command -v age &>/dev/null; then
    echo "age"
  elif command -v gpg &>/dev/null; then
    echo "gpg"
  else
    return 1
  fi
}

# _secrets_lock — encrypt a .env file at rest using age or gpg
_secrets_lock() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local dry_run="${DRY_RUN:-false}"
  local backend=""
  local identity_flag=""
  local recipients_flag=""
  local keep=false
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)    backend="$2";         shift 2 ;;
      --identity)   identity_flag="$2";   shift 2 ;;
      --recipients) recipients_flag="$2"; shift 2 ;;
      --keep)       keep=true;            shift ;;
      --force)      force=true;           shift ;;
      *)            shift ;;
    esac
  done

  # Find local env file
  local local_env
  if ! local_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name"); then
    fail "No local env file found for '$env_name'. Expected: $stack_dir/.${env_name}.env"
    return 1
  fi

  # Detect or validate backend
  if [ -z "$backend" ]; then
    if ! backend=$(_secrets_detect_backend); then
      fail "No encryption backend available. Install 'age' (recommended) or 'gpg'."
      return 1
    fi
  fi
  case "$backend" in
    age|gpg) ;;
    *) fail "Unknown backend: '$backend'. Use 'age' or 'gpg'."; return 1 ;;
  esac

  local env_dir
  env_dir=$(dirname "$local_env")
  local encrypted_file="$env_dir/.${env_name}.env.${backend}"

  print_banner "Secrets Lock"
  log "Stack: $stack | Env: $env_name | Backend: $backend"
  log "Input:  $local_env"
  log "Output: $encrypted_file"
  echo ""

  # Guard against clobbering existing encrypted file
  if [ -f "$encrypted_file" ] && [ "$force" != "true" ]; then
    warn "Encrypted file already exists: $encrypted_file"
    warn "Use --force to overwrite."
    return 1
  fi

  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Would encrypt: $local_env → $encrypted_file${NC}"
    [ "$keep" = "false" ] && echo -e "${YELLOW}[DRY-RUN] Would remove: $local_env${NC}"
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  local tmp_encrypted="${encrypted_file}.tmp"

  if [ "$backend" = "age" ]; then
    # Resolve recipients file
    local rcpts_file="" rcpts_is_temp=false
    if [ -n "$recipients_flag" ]; then
      [ -f "$recipients_flag" ] || { fail "Recipients file not found: $recipients_flag"; return 1; }
      rcpts_file="$recipients_flag"
    elif [ -f "$stack_dir/.strut-recipients" ]; then
      rcpts_file="$stack_dir/.strut-recipients"
    elif [ -f "$CLI_ROOT/.strut-recipients" ]; then
      rcpts_file="$CLI_ROOT/.strut-recipients"
    elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
      rcpts_file=$(mktemp)
      rcpts_is_temp=true
      cp "$HOME/.ssh/id_ed25519.pub" "$rcpts_file"
      warn "No .strut-recipients found — encrypting to self via ~/.ssh/id_ed25519.pub"
    elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
      rcpts_file=$(mktemp)
      rcpts_is_temp=true
      cp "$HOME/.ssh/id_rsa.pub" "$rcpts_file"
      warn "No .strut-recipients found — encrypting to self via ~/.ssh/id_rsa.pub"
    else
      fail "No age recipients configured. Create .strut-recipients with age/SSH public keys, or ensure ~/.ssh/id_ed25519.pub exists."
      return 1
    fi

    age -e -R "$rcpts_file" -o "$tmp_encrypted" "$local_env"
    local exit_code=$?
    [ "$rcpts_is_temp" = "true" ] && rm -f "$rcpts_file"
    if [ "$exit_code" -ne 0 ]; then
      rm -f "$tmp_encrypted"
      fail "age encryption failed"
      return 1
    fi

  elif [ "$backend" = "gpg" ]; then
    gpg --batch --yes --armor --symmetric --output "$tmp_encrypted" "$local_env" || {
      rm -f "$tmp_encrypted"
      fail "gpg encryption failed"
      return 1
    }
  fi

  mv "$tmp_encrypted" "$encrypted_file"
  chmod 600 "$encrypted_file"
  ok "Encrypted: $encrypted_file"

  if [ "$keep" = "false" ]; then
    rm -f "$local_env"
    ok "Removed plaintext: $local_env"
  fi

  echo ""
  log "Safe to commit: $encrypted_file"
  log "Unlock: strut $stack secrets unlock --env $env_name"
}

# _secrets_unlock — decrypt a .env.age or .env.gpg file back to plaintext
_secrets_unlock() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local dry_run="${DRY_RUN:-false}"
  local identity_flag=""
  local keep=false
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --identity) identity_flag="$2"; shift 2 ;;
      --keep)     keep=true;          shift ;;
      --force)    force=true;         shift ;;
      *)          shift ;;
    esac
  done

  # Find encrypted file — stack-level before project-level, age before gpg
  local encrypted_file="" backend=""
  for b in age gpg; do
    for d in "$stack_dir" "$CLI_ROOT"; do
      local candidate="$d/.${env_name}.env.${b}"
      if [ -f "$candidate" ]; then
        encrypted_file="$candidate"
        backend="$b"
        break 2
      fi
    done
  done

  if [ -z "$encrypted_file" ]; then
    fail "No encrypted env file found for '$env_name'. Expected .${env_name}.env.age or .${env_name}.env.gpg"
    return 1
  fi

  local env_dir
  env_dir=$(dirname "$encrypted_file")
  local output_env="$env_dir/.${env_name}.env"

  print_banner "Secrets Unlock"
  log "Stack: $stack | Env: $env_name | Backend: $backend"
  log "Input:  $encrypted_file"
  log "Output: $output_env"
  echo ""

  # Guard against clobbering existing plaintext
  if [ -f "$output_env" ] && [ "$force" != "true" ]; then
    warn "Plaintext env file already exists: $output_env"
    warn "Use --force to overwrite."
    return 1
  fi

  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Would decrypt: $encrypted_file → $output_env${NC}"
    [ "$keep" = "false" ] && echo -e "${YELLOW}[DRY-RUN] Would remove: $encrypted_file${NC}"
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  local tmp_output="${output_env}.tmp"

  if [ "$backend" = "age" ]; then
    # Resolve identity
    local id_file="${identity_flag:-}"
    [ -z "$id_file" ] && id_file="${STRUT_AGE_IDENTITY:-}"
    if [ -z "$id_file" ]; then
      for candidate in "$HOME/.age/key.txt" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
        [ -f "$candidate" ] && { id_file="$candidate"; break; }
      done
    fi
    if [ -z "$id_file" ]; then
      fail "No age identity found. Use --identity <file>, set STRUT_AGE_IDENTITY, or ensure ~/.age/key.txt / ~/.ssh/id_ed25519 exists."
      return 1
    fi

    age -d -i "$id_file" -o "$tmp_output" "$encrypted_file" || {
      rm -f "$tmp_output"
      fail "age decryption failed. Verify your identity can decrypt this file."
      return 1
    }

  elif [ "$backend" = "gpg" ]; then
    gpg --batch --yes --output "$tmp_output" --decrypt "$encrypted_file" || {
      rm -f "$tmp_output"
      fail "gpg decryption failed"
      return 1
    }
  fi

  mv "$tmp_output" "$output_env"
  chmod 600 "$output_env"
  ok "Decrypted: $output_env"

  if [ "$keep" = "false" ]; then
    rm -f "$encrypted_file"
    ok "Removed encrypted file: $encrypted_file"
  fi

  echo ""
  ok "Secrets unlocked — run 'strut $stack secrets push --env $env_name' to sync."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

cmd_secrets() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    hydrate)  _secrets_hydrate "$@" ;;
    push)     _secrets_push "$@" ;;
    pull)     _secrets_pull "$@" ;;
    diff)     _secrets_diff "$@" ;;
    validate) _secrets_validate "$@" ;;
    status)   _secrets_status "$@" ;;
    lock)     _secrets_lock "$@" ;;
    unlock)   _secrets_unlock "$@" ;;
    rotate)   _secrets_rotate "$@" ;;
    template) _secrets_template "$@" ;;
    export)   _secrets_export "$@" ;;
    ""|help|--help|-h) _usage_secrets ;;
    *)
      error "Unknown secrets subcommand: $subcmd"
      _usage_secrets
      return 1
      ;;
  esac
}
