#!/usr/bin/env bash
# ==================================================
# cmd_ssh_keygen.sh — Generate dedicated deploy keypairs
# ==================================================
# Usage: strut <stack> ssh:keygen --name <label> [options]
#
# Generates an ed25519 SSH keypair scoped to the stack's target host,
# optionally authorizes it on the remote, and outputs the private key
# for CI/CD secret storage.
# ==================================================
# Requires: lib/utils.sh, lib/topology.sh sourced first

set -euo pipefail

_usage_ssh_keygen() {
  echo "Usage: strut <stack> ssh:keygen --name <label> [options]"
  echo ""
  echo "Generate a deploy SSH keypair for the stack's target host."
  echo ""
  echo "Options:"
  echo "  --name <label>       Key label/purpose (required). e.g. 'ci', 'github-actions'"
  echo "  --type <algo>        Key type: ed25519 (default) or rsa"
  echo "  --output <mode>      Output private key via: file (default), clipboard, stdout"
  echo "  --no-authorize       Skip adding pubkey to remote authorized_keys"
  echo "  --force              Overwrite existing keypair with same name"
  echo "  --dry-run            Show what would be done without executing"
  echo ""
  echo "Key naming:"
  echo "  Private: ~/.ssh/strut_<host>_<label>"
  echo "  Public:  ~/.ssh/strut_<host>_<label>.pub"
  echo "  Comment: strut-deploy/<host>/<label>@<date>"
  echo ""
  echo "Examples:"
  echo "  strut my-app ssh:keygen --name ci"
  echo "  strut my-app ssh:keygen --name github-actions --output clipboard"
  echo "  strut my-app ssh:keygen --name deploy --no-authorize --output stdout"
  echo ""
}

# _ssh_keygen_resolve_host <stack>
#
# Resolve the target host for keygen. Uses topology first, then env VPS_HOST.
# Sets global variables: _KEYGEN_USER, _KEYGEN_HOST, _KEYGEN_PORT,
# _KEYGEN_KEY_PATH, _KEYGEN_HOST_ALIAS
# Returns 1 if no host can be resolved.
_ssh_keygen_resolve_host() {
  local stack="$1"

  _KEYGEN_USER=""
  _KEYGEN_HOST=""
  _KEYGEN_PORT=""
  _KEYGEN_KEY_PATH=""
  _KEYGEN_HOST_ALIAS=""

  topology_load

  # Try topology first — stack mapped to a host
  if topology_has_host "$stack" 2>/dev/null; then
    local host_alias="${_TOPO_STACK_HOST[$stack]:-}"
    _KEYGEN_HOST_ALIAS="$host_alias"
    local host_spec="${_TOPO_HOSTS[$host_alias]:-}"
    if [ -n "$host_spec" ]; then
      local conn_part
      conn_part="${host_spec%% *}"
      _KEYGEN_KEY_PATH="${host_spec#* }"
      [ "$_KEYGEN_KEY_PATH" = "$conn_part" ] && _KEYGEN_KEY_PATH=""
      if [[ "$conn_part" == *@* ]]; then
        _KEYGEN_USER="${conn_part%%@*}"
        local host_port="${conn_part#*@}"
      else
        _KEYGEN_USER="ubuntu"
        local host_port="$conn_part"
      fi
      if [[ "$host_port" == *:* ]]; then
        _KEYGEN_HOST="${host_port%%:*}"
        _KEYGEN_PORT="${host_port#*:}"
      else
        _KEYGEN_HOST="$host_port"
        _KEYGEN_PORT="22"
      fi
      return 0
    fi
  fi

  # Check if the stack name itself is a host alias
  if topology_is_host_alias "$stack" 2>/dev/null; then
    _KEYGEN_HOST_ALIAS="$stack"
    local host_spec="${_TOPO_HOSTS[$stack]:-}"
    if [ -n "$host_spec" ]; then
      local conn_part
      conn_part="${host_spec%% *}"
      _KEYGEN_KEY_PATH="${host_spec#* }"
      [ "$_KEYGEN_KEY_PATH" = "$conn_part" ] && _KEYGEN_KEY_PATH=""
      if [[ "$conn_part" == *@* ]]; then
        _KEYGEN_USER="${conn_part%%@*}"
        local host_port="${conn_part#*@}"
      else
        _KEYGEN_USER="ubuntu"
        local host_port="$conn_part"
      fi
      if [[ "$host_port" == *:* ]]; then
        _KEYGEN_HOST="${host_port%%:*}"
        _KEYGEN_PORT="${host_port#*:}"
      else
        _KEYGEN_HOST="$host_port"
        _KEYGEN_PORT="22"
      fi
      return 0
    fi
  fi

  # Fallback to env vars
  local vps_host="${VPS_HOST:-}"
  if [ -n "$vps_host" ]; then
    _KEYGEN_USER="${VPS_USER:-ubuntu}"
    _KEYGEN_HOST="$vps_host"
    _KEYGEN_PORT="${VPS_PORT:-22}"
    _KEYGEN_KEY_PATH="${VPS_SSH_KEY:-}"
    _KEYGEN_HOST_ALIAS="$vps_host"
    return 0
  fi

  return 1
}

# _ssh_keygen_clipboard <file>
#
# Copy file contents to clipboard. Detects macOS vs Linux.
_ssh_keygen_clipboard() {
  local file="$1"
  if command -v pbcopy &>/dev/null; then
    cat "$file" | pbcopy
    return 0
  elif command -v xclip &>/dev/null; then
    cat "$file" | xclip -selection clipboard
    return 0
  elif command -v xsel &>/dev/null; then
    cat "$file" | xsel --clipboard --input
    return 0
  else
    return 1
  fi
}

# cmd_ssh_keygen [options] (reads CMD_*)
cmd_ssh_keygen() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local dry_run="${DRY_RUN:-false}"

  local name="" key_type="ed25519" output_mode="file"
  local no_authorize=false force=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)         name="$2"; shift 2 ;;
      --type)         key_type="$2"; shift 2 ;;
      --output)       output_mode="$2"; shift 2 ;;
      --no-authorize) no_authorize=true; shift ;;
      --force)        force=true; shift ;;
      --dry-run)      dry_run=true; shift ;;
      --help|-h)      _usage_ssh_keygen; return 0 ;;
      *)              shift ;;
    esac
  done

  # Validate required args
  if [ -z "$name" ]; then
    fail "Missing required --name <label>. See: strut $stack ssh:keygen --help"
    return 1
  fi

  # Validate key type
  case "$key_type" in
    ed25519|rsa) ;;
    *) fail "Invalid key type '$key_type' — use 'ed25519' or 'rsa'"; return 1 ;;
  esac

  # Validate output mode
  case "$output_mode" in
    file|clipboard|stdout) ;;
    *) fail "Invalid output mode '$output_mode' — use 'file', 'clipboard', or 'stdout'"; return 1 ;;
  esac

  # Source env file for VPS connection fallback
  if [ -f "$env_file" ]; then
    set -a; source "$env_file" 2>/dev/null; set +a
  fi

  # Resolve the target host
  if ! _ssh_keygen_resolve_host "$stack"; then
    fail "Cannot resolve target host for '$stack'. Add to [hosts]/[stacks] in strut.conf or set VPS_HOST."
    return 1
  fi
  local user="$_KEYGEN_USER"
  local host="$_KEYGEN_HOST"
  local port="$_KEYGEN_PORT"
  local key_path="$_KEYGEN_KEY_PATH"
  local host_alias="$_KEYGEN_HOST_ALIAS"

  # Determine key paths
  local key_dir="$HOME/.ssh"
  local key_name="strut_${host_alias}_${name}"
  local key_path_private="$key_dir/$key_name"
  local key_path_public="$key_dir/${key_name}.pub"
  local key_comment="strut-deploy/${host_alias}/${name}@$(date +%Y-%m-%d)"

  print_banner "SSH Key Generation"
  log "Stack: $stack → Host: $host_alias ($user@$host:$port)"
  log "Key: $key_path_private"
  log "Type: $key_type"
  log "Comment: $key_comment"
  [ "$no_authorize" = "true" ] && log "Authorization: skipped (--no-authorize)"
  echo ""

  # ── Dry-run ──────────────────────────────────────────────────────────────
  if [ "$dry_run" = "true" ]; then
    echo -e "${YELLOW}[DRY-RUN] Execution plan:${NC}"
    run_cmd "Generate $key_type keypair" ssh-keygen -t "$key_type" -f "$key_path_private" -N "" -C "$key_comment"
    if [ "$no_authorize" != "true" ]; then
      run_cmd "Authorize on $host_alias" "cat $key_path_public | ssh $user@$host 'cat >> ~/.ssh/authorized_keys'"
    fi
    case "$output_mode" in
      clipboard) run_cmd "Copy private key to clipboard" "cat $key_path_private | pbcopy" ;;
      stdout)    run_cmd "Print private key to stdout" "cat $key_path_private" ;;
      file)      run_cmd "Private key saved at" "echo $key_path_private" ;;
    esac
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # ── Check existing ───────────────────────────────────────────────────────
  if [ -f "$key_path_private" ]; then
    if [ "$force" != "true" ]; then
      fail "Key already exists: $key_path_private"
      warn "Use --force to overwrite, or choose a different --name."
      return 1
    fi
    warn "Overwriting existing key: $key_path_private"
    rm -f "$key_path_private" "$key_path_public"
  fi

  # ── Generate ─────────────────────────────────────────────────────────────
  log "[1/3] Generating $key_type keypair..."
  mkdir -p "$key_dir"
  chmod 700 "$key_dir"

  if [ "$key_type" = "rsa" ]; then
    ssh-keygen -t rsa -b 4096 -f "$key_path_private" -N "" -C "$key_comment" -q
  else
    ssh-keygen -t ed25519 -f "$key_path_private" -N "" -C "$key_comment" -q
  fi

  chmod 600 "$key_path_private"
  chmod 644 "$key_path_public"

  local fingerprint
  fingerprint=$(ssh-keygen -lf "$key_path_public" 2>/dev/null | awk '{print $2}')
  ok "Keypair generated"
  log "  Fingerprint: $fingerprint"

  # ── Authorize ────────────────────────────────────────────────────────────
  if [ "$no_authorize" != "true" ]; then
    log "[2/3] Authorizing on $host_alias ($user@$host)..."

    local ssh_opts
    ssh_opts=$(build_ssh_opts -p "$port" -k "$key_path" --batch)

    # Ensure .ssh directory exists on remote
    # shellcheck disable=SC2029
    ssh $ssh_opts "$user@$host" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null || {
      warn "Could not create ~/.ssh on remote — authorization skipped"
      warn "Manually add the pubkey: cat $key_path_public >> remote:~/.ssh/authorized_keys"
      log "[2/3] Skipped (connection failed)"
      # Continue — key is still generated
    }

    # Append pubkey (idempotent: check if already present)
    local pubkey_content
    pubkey_content=$(cat "$key_path_public")

    # shellcheck disable=SC2029
    if ssh $ssh_opts "$user@$host" "grep -qF '$key_comment' ~/.ssh/authorized_keys 2>/dev/null" 2>/dev/null; then
      log "  Key already authorized (comment match)"
    else
      # shellcheck disable=SC2029
      if echo "$pubkey_content" | ssh $ssh_opts "$user@$host" "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null; then
        ok "Public key authorized on $host_alias"
      else
        warn "Authorization failed — add manually:"
        warn "  cat $key_path_public | ssh $user@$host 'cat >> ~/.ssh/authorized_keys'"
      fi
    fi
  else
    log "[2/3] Authorization skipped (--no-authorize)"
  fi

  # ── Output ───────────────────────────────────────────────────────────────
  log "[3/3] Output..."
  case "$output_mode" in
    clipboard)
      if _ssh_keygen_clipboard "$key_path_private"; then
        ok "Private key copied to clipboard"
      else
        warn "No clipboard tool found (pbcopy/xclip/xsel) — printing path instead"
        log "  Private key: $key_path_private"
      fi
      ;;
    stdout)
      echo ""
      echo "--- BEGIN PRIVATE KEY ---"
      cat "$key_path_private"
      echo "--- END PRIVATE KEY ---"
      echo ""
      ;;
    file)
      ok "Private key: $key_path_private"
      ;;
  esac

  # ── Summary ──────────────────────────────────────────────────────────────
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Key:         $key_path_private"
  echo "  Public:      $key_path_public"
  echo "  Fingerprint: $fingerprint"
  echo "  Comment:     $key_comment"
  echo "  Host:        $user@$host:$port"
  [ "$no_authorize" != "true" ] && echo "  Authorized:  yes"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  log "Next steps:"
  log "  • Store the private key in your CI secrets (e.g. gh secret set DEPLOY_SSH_KEY < $key_path_private)"
  log "  • Run 'strut $stack ci:init' to bootstrap all CI secrets at once"
}
