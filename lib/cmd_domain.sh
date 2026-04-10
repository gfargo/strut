#!/usr/bin/env bash
# ==================================================
# cmd_domain.sh — Domain/SSL configuration command handler
# ==================================================

set -euo pipefail

# cmd_domain <stack> <env_file> <env_name> [domain] [email] [--skip-ssl]
cmd_domain() {
  local stack="$1"
  local env_file="$2"
  local env_name="$3"
  shift 3

  # Parse domain-specific args
  local domain=""
  local email=""
  local skip_ssl=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --skip-ssl) skip_ssl=true; shift ;;
      -*) shift ;;
      *)
        if [ -z "$domain" ]; then domain="$1"
        elif [ -z "$email" ]; then email="$1"
        fi
        shift
        ;;
    esac
  done

  [ -n "$domain" ] || fail "Usage: strut $stack domain <domain> <email> [--skip-ssl]"
  [ -n "$email" ] || fail "Usage: strut $stack domain <domain> <email> [--skip-ssl]"
  validate_env_file "$env_file" VPS_HOST

  local skip_ssl_flag=""
  $skip_ssl && skip_ssl_flag="--skip-ssl"

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir="${VPS_DEPLOY_DIR:-/home/${vps_user}/strut}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # scp uses -P (uppercase) for port, not -p — build separate opts
  local scp_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
  [ -n "$vps_port" ] && scp_opts="-P $vps_port $scp_opts"
  [ -n "$vps_ssh_key" ] && scp_opts="$scp_opts -i $vps_ssh_key"

  log "Running configure-domain.sh on $vps_user@$vps_host..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" \
    "bash '$deploy_dir/scripts/configure-domain.sh' '$stack' '$domain' '$email' --env '${env_name:-prod}' $skip_ssl_flag"

  # Pull the updated nginx conf back locally
  local nginx_conf_local="$CLI_ROOT/stacks/$stack/nginx/conf.d/${stack}.conf"
  local nginx_conf_remote="$deploy_dir/stacks/$stack/nginx/conf.d/${stack}.conf"
  log "Pulling updated nginx conf back to local repo..."
  scp $scp_opts \
    "$vps_user@$vps_host:$nginx_conf_remote" \
    "$nginx_conf_local" \
    && ok "nginx conf updated locally"

  # Auto-commit and push the SSL config unless --skip-ssl was used
  if ! $skip_ssl; then
    log "Committing SSL configuration to git..."
    if git -C "$CLI_ROOT" diff --quiet "$nginx_conf_local"; then
      ok "No changes to commit (SSL config already in git)"
    else
      git -C "$CLI_ROOT" add "$nginx_conf_local"
      git -C "$CLI_ROOT" commit -m "[SSL] Configure HTTPS for $domain on $stack stack"
      if git -C "$CLI_ROOT" push; then
        ok "SSL config committed and pushed to git"
        log "Updating VPS repo to sync SSL config..."
        ssh $ssh_opts "$vps_user@$vps_host" \
          "cd '$deploy_dir' && git pull origin main"
        log "Restarting nginx to load updated config..."
        ssh $ssh_opts "$vps_user@$vps_host" \
          "cd '$deploy_dir' && docker compose --project-name ${env_name:-prod} restart nginx"
        ok "VPS nginx restarted with SSL config"
      else
        warn "Failed to push to git — you may need to manually push and update VPS"
      fi
    fi
  fi
}
