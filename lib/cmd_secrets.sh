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
  echo "Sync environment files between local and VPS."
  echo ""
  echo "Subcommands:"
  echo "  hydrate    Build local .env from a template, resolving secret references"
  echo "  push       Upload local .env to VPS (SCP, mode 600)"
  echo "  pull       Download .env from VPS to local"
  echo "  diff       Show differences between local and remote .env"
  echo "  validate   Check required_vars are present before push"
  echo ""
  echo "Options:"
  echo "  --env <name>   Environment name (default: prod)"
  echo "  --dry-run      Preview without executing"
  echo "  --force        Overwrite local/remote file without confirmation"
  echo ""
  echo "Secret references (in a .env template, resolved by 'hydrate'):"
  echo "  KEY=vault://<item>     Vaultwarden/Bitwarden item (via 'bw')"
  echo "  KEY=exec://<command>   Stdout of a command"
  echo "  KEY=file://<path>      Contents of a file (e.g. /run/secrets/x)"
  echo "  KEY=plain-value        Literal — copied as-is"
  echo ""
  echo "  Note: exec:// runs commands with your privileges — only hydrate templates you trust."
  echo ""
  echo "Examples:"
  echo "  strut my-app secrets hydrate --env prod      # template -> .prod.env"
  echo "  strut my-app secrets push --env prod"
  echo "  strut my-app secrets pull --env prod"
  echo "  strut my-app secrets diff --env prod"
  echo "  strut my-app secrets validate --env prod"
  echo "  strut my-app secrets push --env staging --dry-run"
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

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=true; shift ;;
      *) shift ;;
    esac
  done

  # Find local env file
  local local_env
  if ! local_env=$(_secrets_resolve_local_env "$stack_dir" "$env_name"); then
    fail "No local env file found for '$env_name'. Expected: $stack_dir/.${env_name}.env or $CLI_ROOT/.${env_name}.env"
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

  # Validate required vars before pushing
  if ! _secrets_validate_required_vars "$local_env" "$stack_dir"; then
    echo ""
    warn "Push aborted — fill in missing variables first."
    warn "Use: strut $stack init-secrets --env $env_name"
    return 1
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

  # Download
  log "Downloading..."
  local scp_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
  [[ -n "$vps_port" && "$vps_port" != "22" ]] && scp_opts="$scp_opts -P $vps_port"
  [[ -n "$vps_ssh_key" ]] && scp_opts="$scp_opts -o IdentitiesOnly=yes -i $vps_ssh_key"
  if ssh_mux_enabled 2>/dev/null; then
    local ctl_path
    ctl_path=$(ssh_mux_control_path)
    scp_opts="$scp_opts -o ControlMaster=auto -o ControlPath=$ctl_path -o ControlPersist=60s"
  fi

  # shellcheck disable=SC2086
  scp $scp_opts "$vps_user@$vps_host:$remote_path" "$local_env" || fail "Download failed"
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

  # Fetch remote to tmp
  local tmp_remote="/tmp/strut-secrets-diff-remote-$$"
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

  if _secrets_validate_required_vars "$local_env" "$stack_dir"; then
    local var_count
    var_count=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$local_env" 2>/dev/null || echo "0")
    ok "All required variables present ($var_count total vars)"
  else
    return 1
  fi
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
    ""|help|--help|-h) _usage_secrets ;;
    *)
      error "Unknown secrets subcommand: $subcmd"
      _usage_secrets
      return 1
      ;;
  esac
}
