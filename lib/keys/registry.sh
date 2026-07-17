#!/usr/bin/env bash
# ==================================================
# lib/keys/registry.sh — Docker registry pull credential management
# ==================================================
# Rotate pull tokens for private registries (ghcr.io) across VPS hosts.
# Tokens are never echoed or logged — delivered via --password-stdin.
#
# GitHub does not expose a PAT-creation API, so "regenerate" means:
#   1. User mints a new PAT in the GitHub UI (or reuses a gh CLI token).
#   2. Strut distributes it to all hosts via docker login --password-stdin.
#   3. Old PAT must be revoked manually (--revoke-old prints guidance).
# Future: GitHub App installation tokens avoid the static-PAT limitation.

set -euo pipefail

# _registry_host_list <vps_host> <hosts_override>
# Outputs one hostname per line.
# Uses vps_host when hosts_override is empty or "all".
# Expands a comma-separated list when hosts_override is set.
_registry_host_list() {
  local vps_host="${1:-}"
  local hosts_override="${2:-all}"

  if [ -n "$hosts_override" ] && [ "$hosts_override" != "all" ]; then
    local IFS=','
    read -ra _rl <<< "$hosts_override"
    local h
    for h in "${_rl[@]}"; do
      printf '%s\n' "$h"
    done
  elif [ -n "$vps_host" ]; then
    printf '%s\n' "$vps_host"
  fi
}

# keys_registry_rotate <stack> [options]
#
# Options:
#   --registry <url>      Registry URL (default: ghcr.io)
#   --hosts <list|all>    Comma-separated hostnames, or "all" (default: VPS_HOST from env)
#   --username <user>     Registry username (default: GHCR_USER/GITHUB_USER from env)
#   --revoke-old          Print PAT revocation guidance after rotation
#   --dry-run             Show what would change without applying
#   --env-file <path>     VPS credential env file (default: $CLI_ROOT/.prod.env)
#
# Token is read from stdin: hidden prompt on a tty, raw read otherwise.
# The token is never echoed, stored, or written to any log.
keys_registry_rotate() {
  local stack="$1"
  shift || true

  local registry="ghcr.io"
  local hosts_override="all"
  local revoke_old=false
  local dry_run=false
  local reg_username=""
  local env_file="$CLI_ROOT/.prod.env"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --registry=*) registry="${1#*=}"; shift ;;
      --registry)   registry="$2"; shift 2 ;;
      --hosts=*)    hosts_override="${1#*=}"; shift ;;
      --hosts)      hosts_override="$2"; shift 2 ;;
      --username=*) reg_username="${1#*=}"; shift ;;
      --username)   reg_username="$2"; shift 2 ;;
      --revoke-old) revoke_old=true; shift ;;
      --dry-run)    dry_run=true; shift ;;
      --env-file=*) env_file="${1#*=}"; shift ;;
      --env-file)   env_file="$2"; shift 2 ;;
      *) warn "Unknown flag: $1"; shift ;;
    esac
  done

  # Load VPS credentials from env file
  local vps_host="" vps_user="ubuntu" vps_ssh_key="" vps_port="22"
  if [ -f "$env_file" ]; then
    safe_load_env "$env_file"
    vps_host="${VPS_HOST:-}"
    vps_user="${VPS_USER:-ubuntu}"
    vps_ssh_key="${VPS_SSH_KEY:-}"
    vps_port="${VPS_PORT:-22}"
    if [ -z "$reg_username" ]; then
      reg_username="${GHCR_USER:-${GITHUB_USER:-${REGISTRY_USER:-}}}"
    fi
  fi

  if [ -z "$reg_username" ]; then
    fail "Registry username required — set GHCR_USER/GITHUB_USER in $env_file or pass --username <user>"
  fi

  # Build host list
  local host_list=()
  while IFS= read -r h; do
    [ -n "$h" ] && host_list+=("$h")
  done < <(_registry_host_list "$vps_host" "$hosts_override")

  if [ ${#host_list[@]} -eq 0 ]; then
    fail "No hosts configured — set VPS_HOST in $env_file or pass --hosts <list>"
  fi

  echo ""
  echo -e "${BLUE}Registry credential rotation${NC}"
  echo "  Registry : $registry"
  echo "  Username : $reg_username"
  echo "  Hosts    : ${host_list[*]}"

  if $dry_run; then
    echo ""
    show_dry_run_changes "registry:rotate" \
      "docker login $registry --username $reg_username --password-stdin on ${#host_list[@]} host(s)"
    if $revoke_old; then
      echo "  [revoke-old] Would print PAT revocation guidance after rotation"
    fi
    return 0
  fi

  echo ""

  # Read token securely — never stored beyond this local variable scope
  local token
  if [ -t 0 ]; then
    echo "Enter new $registry token (input hidden):"
    read -rs token
    echo ""
  else
    IFS= read -r token
  fi

  [ -n "$token" ] || fail "No token provided"

  ensure_keys_dir "$stack"
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local meta_file="$keys_dir/registry-credentials.json"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Initialize metadata file if absent or corrupted
  if [ ! -f "$meta_file" ] || ! jq empty "$meta_file" 2>/dev/null; then
    echo '{"registry_hosts": {}, "last_updated": ""}' > "$meta_file"
  fi

  local success_count=0
  local fail_count=0

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  echo "Rotating pull credentials..."
  echo ""

  local host
  for host in "${host_list[@]}"; do
    printf "  %-30s " "$host"

    if ! validate_vps_connection "$host" "$vps_user" "$vps_ssh_key" "$vps_port" 5 2>/dev/null; then
      echo -e "${RED}✗ unreachable${NC}"
      log_key_operation "$stack" "registry:rotate" \
        "registry=$registry host=$host" --failed
      jq --arg h "$host" --arg r "$registry" --arg u "$reg_username" --arg ts "$ts" \
        'if .registry_hosts[$h] then
           .registry_hosts[$h] |= . + {registry: $r, username: $u, status: "unreachable"}
         else
           .registry_hosts[$h] = {registry: $r, username: $u, last_rotated: null, status: "unreachable"}
         end' \
        "$meta_file" > "$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
      fail_count=$(( fail_count + 1 ))
      continue
    fi

    # Deliver token via stdin — never echoed or logged by docker or SSH
    if printf '%s' "$token" | ssh $ssh_opts "$vps_user@$host" \
        "docker login '$registry' --username '$reg_username' --password-stdin" \
        >/dev/null 2>&1; then
      echo -e "${GREEN}✓ logged in${NC}"
      log_key_operation "$stack" "registry:rotate" \
        "registry=$registry host=$host user=$reg_username"
      jq --arg h "$host" --arg r "$registry" --arg u "$reg_username" --arg ts "$ts" \
        '.registry_hosts[$h] = {registry: $r, username: $u, last_rotated: $ts, status: "ok"}' \
        "$meta_file" > "$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
      success_count=$(( success_count + 1 ))
    else
      echo -e "${RED}✗ login failed${NC}"
      log_key_operation "$stack" "registry:rotate" \
        "registry=$registry host=$host" --failed
      jq --arg h "$host" --arg r "$registry" --arg u "$reg_username" --arg ts "$ts" \
        'if .registry_hosts[$h] then
           .registry_hosts[$h] |= . + {registry: $r, username: $u, status: "login_failed"}
         else
           .registry_hosts[$h] = {registry: $r, username: $u, last_rotated: null, status: "login_failed"}
         end' \
        "$meta_file" > "$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"
      fail_count=$(( fail_count + 1 ))
    fi
  done

  jq --arg ts "$ts" '.last_updated = $ts' \
    "$meta_file" > "$meta_file.tmp" && mv "$meta_file.tmp" "$meta_file"

  echo ""
  if [ "$fail_count" -eq 0 ]; then
    ok "All ${success_count} host(s) updated"
  else
    echo "Results: ${success_count} succeeded, ${fail_count} failed"
    [ "$success_count" -eq 0 ] && return 1
  fi

  if $revoke_old; then
    echo ""
    warn "GitHub does not support programmatic PAT revocation via API."
    echo "  Revoke the old token manually:"
    echo "    Classic PATs      : https://github.com/settings/tokens"
    echo "    Fine-grained PATs : https://github.com/settings/personal-access-tokens"
  fi
}

# keys_registry_status <stack> [options]
#
# Options:
#   --registry <url>    Registry to check (default: ghcr.io)
#   --hosts <list|all>  Hosts to check (default: VPS_HOST from env)
#   --json              Output in JSON format
#   --env-file <path>   VPS credential env file
#
# Per-host auth check reads ~/.docker/config.json on the remote.
# If the host uses a credential store (credsStore), the auth entry may not
# appear in config.json — reported as "logged_in" may be inaccurate in that case.
keys_registry_status() {
  local stack="$1"
  shift || true

  local registry="ghcr.io"
  local hosts_override="all"
  local json_output=false
  local env_file="$CLI_ROOT/.prod.env"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --registry=*) registry="${1#*=}"; shift ;;
      --registry)   registry="$2"; shift 2 ;;
      --hosts=*)    hosts_override="${1#*=}"; shift ;;
      --hosts)      hosts_override="$2"; shift 2 ;;
      --json)       json_output=true; shift ;;
      --env-file=*) env_file="${1#*=}"; shift ;;
      --env-file)   env_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local vps_host="" vps_user="ubuntu" vps_ssh_key="" vps_port="22"
  if [ -f "$env_file" ]; then
    safe_load_env "$env_file"
    vps_host="${VPS_HOST:-}"
    vps_user="${VPS_USER:-ubuntu}"
    vps_ssh_key="${VPS_SSH_KEY:-}"
    vps_port="${VPS_PORT:-22}"
  fi

  local host_list=()
  while IFS= read -r h; do
    [ -n "$h" ] && host_list+=("$h")
  done < <(_registry_host_list "$vps_host" "$hosts_override")

  if [ ${#host_list[@]} -eq 0 ]; then
    if $json_output; then
      echo '{"error": "no hosts configured"}'
    else
      warn "No hosts configured — set VPS_HOST in $env_file"
    fi
    return 1
  fi

  ensure_keys_dir "$stack"
  local keys_dir
  keys_dir=$(get_keys_dir "$stack")
  local meta_file="$keys_dir/registry-credentials.json"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Collect per-host status as "host|reachable|auth_status|last_rotated|username"
  local results=()
  local host
  for host in "${host_list[@]}"; do
    local reachable="false"
    local auth_status="unknown"

    if validate_vps_connection "$host" "$vps_user" "$vps_ssh_key" "$vps_port" 5 2>/dev/null; then
      reachable="true"
      # Check docker auth entry on the remote host.
      # $registry expands locally (desired); \$HOME and \$cfg expand on remote.
      local remote_check
      remote_check=$(ssh $ssh_opts "$vps_user@$host" \
        "cfg=\"\$HOME/.docker/config.json\"; if [ ! -f \"\$cfg\" ]; then echo no_config; elif jq -e --arg r '$registry' '.auths[\$r] // null | . != null' \"\$cfg\" >/dev/null 2>&1; then echo logged_in; else echo not_logged_in; fi" \
        2>/dev/null || echo "ssh_error")
      auth_status="$remote_check"
    fi

    local last_rotated="never"
    local meta_user="—"
    if [ -f "$meta_file" ]; then
      last_rotated=$(jq -r --arg h "$host" \
        '.registry_hosts[$h].last_rotated // "never"' \
        "$meta_file" 2>/dev/null || echo "never")
      meta_user=$(jq -r --arg h "$host" \
        '.registry_hosts[$h].username // "—"' \
        "$meta_file" 2>/dev/null || echo "—")
      [ "$last_rotated" = "null" ] && last_rotated="never"
      [ "$meta_user" = "null" ] && meta_user="—"
    fi

    results+=("${host}|${reachable}|${auth_status}|${last_rotated}|${meta_user}")
  done

  if $json_output; then
    local first=true
    printf '{"registry":"%s","hosts":[' "$registry"
    local entry
    for entry in "${results[@]}"; do
      local h reach auth lr mu
      IFS='|' read -r h reach auth lr mu <<< "$entry"
      $first || printf ','
      first=false
      printf '{"host":"%s","reachable":%s,"auth_status":"%s","last_rotated":"%s","username":"%s"}' \
        "$h" "$reach" "$auth" "$lr" "$mu"
    done
    printf ']\n}\n'
    return 0
  fi

  echo ""
  echo -e "${BLUE}Registry Status: $registry${NC}"
  echo ""

  local entry
  for entry in "${results[@]}"; do
    local h reach auth lr mu
    IFS='|' read -r h reach auth lr mu <<< "$entry"

    local reach_sym auth_sym
    if [ "$reach" = "true" ]; then
      reach_sym="${GREEN}✓${NC}"
    else
      reach_sym="${RED}✗${NC}"
    fi

    case "$auth" in
      logged_in)     auth_sym="${GREEN}✓ logged in${NC}" ;;
      not_logged_in) auth_sym="${RED}✗ not logged in${NC}" ;;
      no_config)     auth_sym="${YELLOW}? no docker config${NC}" ;;
      *)             auth_sym="${YELLOW}? ${auth}${NC}" ;;
    esac

    echo -e "  ${BLUE}$h${NC}"
    echo -e "    Reachable   : $reach_sym"
    echo -e "    Auth        : $auth_sym"
    echo    "    User        : $mu"
    echo    "    Last rotated: $lr"
    echo ""
  done
}
