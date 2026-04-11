#!/usr/bin/env bash
# ==================================================
# cmd_domain.sh — Domain/SSL configuration command handler
# ==================================================

set -euo pipefail

_usage_domain() {
  echo ""
  echo "Usage: strut <stack> domain [--env <name>] <domain> <email> [--skip-ssl]"
  echo ""
  echo "Configure domain and SSL for a stack on VPS."
  echo "  nginx: runs configure-domain.sh + certbot"
  echo "  caddy: updates Caddyfile (Caddy handles ACME automatically)"
  echo ""
  echo "Flags:"
  echo "  --skip-ssl           Skip SSL certificate setup and git commit"
  echo ""
  echo "Examples:"
  echo "  strut my-stack domain example.com admin@example.com --env prod"
  echo "  strut my-stack domain example.com admin@example.com --env prod --skip-ssl"
  echo ""
}

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

  local proxy="${REVERSE_PROXY:-nginx}"
  local conf_local=""
  local conf_remote=""

  # Dry-run: show execution plan and exit early
  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for domain:${NC}"
    case "$proxy" in
      nginx)
        run_cmd "Run configure-domain.sh on VPS" ssh "$vps_user@$vps_host" "configure-domain.sh $stack $domain $email"
        run_cmd "Pull updated nginx conf from VPS" scp "$vps_user@$vps_host:.../${stack}.conf" "stacks/$stack/nginx/conf.d/"
        ;;
      caddy)
        run_cmd "Update Caddyfile on VPS with domain $domain" ssh "$vps_user@$vps_host" "sed Caddyfile"
        run_cmd "Reload Caddy on VPS" ssh "$vps_user@$vps_host" "caddy reload"
        run_cmd "Pull updated Caddyfile from VPS" scp "$vps_user@$vps_host:.../Caddyfile" "stacks/$stack/caddy/"
        ;;
    esac
    if ! $skip_ssl; then
      run_cmd "Commit SSL config to git" git commit -m "[SSL] Configure HTTPS for $domain"
      run_cmd "Push to git" git push origin main
      run_cmd "Update VPS repo" ssh "$vps_user@$vps_host" "git pull origin main"
      run_cmd "Restart $proxy on VPS" ssh "$vps_user@$vps_host" "docker compose restart $proxy"
    fi
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  case "$proxy" in
    nginx)
      log "Running configure-domain.sh on $vps_user@$vps_host..."
      # shellcheck disable=SC2029
      ssh $ssh_opts "$vps_user@$vps_host" \
        "bash '$deploy_dir/scripts/configure-domain.sh' '$stack' '$domain' '$email' --env '${env_name:-prod}' $skip_ssl_flag"

      conf_local="$CLI_ROOT/stacks/$stack/nginx/conf.d/${stack}.conf"
      conf_remote="$deploy_dir/stacks/$stack/nginx/conf.d/${stack}.conf"
      log "Pulling updated nginx conf back to local repo..."
      scp $scp_opts \
        "$vps_user@$vps_host:$conf_remote" \
        "$conf_local" \
        && ok "nginx conf updated locally"
      ;;
    caddy)
      conf_local="$CLI_ROOT/stacks/$stack/caddy/Caddyfile"
      conf_remote="$deploy_dir/stacks/$stack/caddy/Caddyfile"

      # Update Caddyfile on VPS with domain block — Caddy handles ACME automatically
      log "Updating Caddyfile on VPS for domain $domain..."
      # shellcheck disable=SC2029
      ssh $ssh_opts "$vps_user@$vps_host" \
        "cd '$deploy_dir/stacks/$stack' && sed -i 's/^# *:80 {/$domain {/' caddy/Caddyfile"

      log "Reloading Caddy on VPS..."
      # shellcheck disable=SC2029
      ssh $ssh_opts "$vps_user@$vps_host" \
        "cd '$deploy_dir' && docker compose --project-name ${env_name:-prod} exec -T caddy caddy reload --config /etc/caddy/Caddyfile" \
        && ok "Caddy reloaded with domain $domain" \
        || warn "Caddy reload failed — check Caddyfile syntax"

      log "Pulling updated Caddyfile back to local repo..."
      scp $scp_opts \
        "$vps_user@$vps_host:$conf_remote" \
        "$conf_local" \
        && ok "Caddyfile updated locally"
      ;;
  esac

  # Auto-commit and push the SSL config unless --skip-ssl was used
  # (For caddy, --skip-ssl skips the git commit/push, not certbot — Caddy handles ACME natively)
  if ! $skip_ssl; then
    log "Committing SSL configuration to git..."
    if git -C "$CLI_ROOT" diff --quiet "$conf_local"; then
      ok "No changes to commit (SSL config already in git)"
    else
      git -C "$CLI_ROOT" add "$conf_local"
      git -C "$CLI_ROOT" commit -m "[SSL] Configure HTTPS for $domain on $stack stack"
      if git -C "$CLI_ROOT" push; then
        ok "SSL config committed and pushed to git"
        log "Updating VPS repo to sync SSL config..."
        ssh $ssh_opts "$vps_user@$vps_host" \
          "cd '$deploy_dir' && git pull origin main"
        log "Restarting $proxy to load updated config..."
        ssh $ssh_opts "$vps_user@$vps_host" \
          "cd '$deploy_dir' && docker compose --project-name ${env_name:-prod} restart $proxy"
        ok "VPS $proxy restarted with SSL config"
      else
        warn "Failed to push to git — you may need to manually push and update VPS"
      fi
    fi
  fi
}
