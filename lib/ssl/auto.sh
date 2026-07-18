#!/usr/bin/env bash
# ==================================================
# lib/ssl/auto.sh — Auto-SSL provisioning on deploy
# ==================================================
# Detects domains from compose labels or env vars and provisions
# Let's Encrypt certificates automatically after a successful deploy.
#
# Provides:
#   ssl_auto_provision  — detect + provision certs for a stack

set -euo pipefail

# ssl_auto_provision <stack> <env_file> <ssh_opts> <vps_user> <vps_host> <deploy_dir>
#
# Called after a successful deploy+health-check. Detects configured domains
# and provisions SSL certificates that don't already exist or are expiring.
#
# Domain detection sources (checked in order):
#   1. Compose label: strut.domain on any service
#   2. Env var: DOMAIN or DOMAINS (comma-separated)
#   3. Env var: VIRTUAL_HOST (nginx-proxy compat)
#
# Skips if:
#   - AUTO_SSL=false in env or strut.conf
#   - Domain doesn't resolve to the VPS IP (DNS not ready)
#   - Cert already exists and is valid for >30 days
ssl_auto_provision() {
  local stack="$1"
  local env_file="$2"
  local ssh_opts="$3"
  local vps_user="$4"
  local vps_host="$5"
  local deploy_dir="$6"

  # Check if auto-SSL is disabled
  local auto_ssl="${AUTO_SSL:-true}"
  if [ "$auto_ssl" = "false" ] || [ "$auto_ssl" = "0" ]; then
    return 0
  fi

  # Detect domains
  local domains
  domains=$(_ssl_detect_domains "$stack" "$env_file" "$ssh_opts" "$vps_user" "$vps_host" "$deploy_dir")

  [ -n "$domains" ] || return 0

  local ssl_email="${SSL_EMAIL:-}"
  if [ -z "$ssl_email" ]; then
    # No email configured — skip auto-SSL silently
    return 0
  fi

  local domain
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    _ssl_provision_one "$domain" "$ssl_email" "$ssh_opts" "$vps_user" "$vps_host" "$deploy_dir" "$stack"
  done <<< "$domains"
}

# _ssl_detect_domains <stack> <env_file> <ssh_opts> <user> <host> <deploy_dir>
#
# Returns one domain per line.
_ssl_detect_domains() {
  local stack="$1"
  local env_file="$2"
  local ssh_opts="$3"
  local vps_user="$4"
  local vps_host="$5"
  local deploy_dir="$6"

  local domains=""

  # Source 1: compose labels (strut.domain). `docker compose config`
  # renders labels inline on one line (`strut.domain: example.com`, or
  # `"strut.domain": "example.com"` under --format json, or
  # `strut.domain=example.com` for list-form labels) — the value is never
  # on the line AFTER the key. Match "strut.domain" plus the run of
  # non-alphanumeric separator chars after it (quotes/colon/equals/space,
  # in any combination), then capture the trailing domain-shaped token.
  # This intentionally avoids matching quote characters literally, which
  # would need escaping across two more layers of quoting (this local
  # double-quoted string, then the remote shell) (strut#395).
  # shellcheck disable=SC2029
  local label_domains
  label_domains=$(ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir' 2>/dev/null || exit 0
    docker compose -f 'stacks/$stack/docker-compose.yml' config 2>/dev/null \
      | grep -oE 'strut\.domain[^A-Za-z0-9]*[A-Za-z0-9.-]+' \
      | grep -oE '[A-Za-z0-9.-]+\$' || true
  " 2>/dev/null) || true
  [ -n "$label_domains" ] && domains="$label_domains"

  # Source 2: env vars (DOMAIN, DOMAINS, VIRTUAL_HOST)
  local env_domain="${DOMAIN:-}"
  local env_domains="${DOMAINS:-}"
  local env_vhost="${VIRTUAL_HOST:-}"

  if [ -n "$env_domain" ]; then
    domains="${domains:+$domains
}$env_domain"
  fi
  if [ -n "$env_domains" ]; then
    # Comma-separated → newline-separated
    domains="${domains:+$domains
}$(echo "$env_domains" | tr ',' '\n')"
  fi
  if [ -n "$env_vhost" ]; then
    domains="${domains:+$domains
}$(echo "$env_vhost" | tr ',' '\n')"
  fi

  # Deduplicate and trim
  echo "$domains" | sort -u | sed '/^$/d'
}

# _ssl_provision_one <domain> <email> <ssh_opts> <user> <host> <deploy_dir> <stack>
_ssl_provision_one() {
  local domain="$1"
  local email="$2"
  local ssh_opts="$3"
  local vps_user="$4"
  local vps_host="$5"
  local deploy_dir="$6"
  local stack="$7"

  # Check if cert already exists and is valid
  # shellcheck disable=SC2029
  local cert_status
  cert_status=$(ssh $ssh_opts "$vps_user@$vps_host" "
    if [ -f '/etc/letsencrypt/live/$domain/fullchain.pem' ]; then
      expiry=\$(openssl x509 -enddate -noout -in '/etc/letsencrypt/live/$domain/fullchain.pem' 2>/dev/null | cut -d= -f2)
      if [ -n \"\$expiry\" ]; then
        expiry_epoch=\$(date -d \"\$expiry\" +%s 2>/dev/null || date -j -f '%b %d %T %Y %Z' \"\$expiry\" +%s 2>/dev/null || echo 0)
        now_epoch=\$(date +%s)
        days_left=\$(( (expiry_epoch - now_epoch) / 86400 ))
        if [ \"\$days_left\" -gt 30 ]; then
          echo 'valid'
        else
          echo 'expiring'
        fi
      else
        echo 'unknown'
      fi
    else
      echo 'missing'
    fi
  " 2>/dev/null) || cert_status="error"

  if [ "$cert_status" = "valid" ]; then
    return 0  # Cert is fine, skip
  fi

  # Check DNS resolves to this host
  # shellcheck disable=SC2029
  local dns_ok
  dns_ok=$(ssh $ssh_opts "$vps_user@$vps_host" "
    my_ip=\$(curl -s4 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print \$1}')
    domain_ip=\$(dig +short '$domain' 2>/dev/null | head -1)
    if [ \"\$my_ip\" = \"\$domain_ip\" ]; then
      echo 'yes'
    else
      echo 'no'
    fi
  " 2>/dev/null) || dns_ok="no"

  if [ "$dns_ok" != "yes" ]; then
    warn "auto-ssl: $domain does not resolve to VPS IP (DNS not ready?) — skipping"
    return 0
  fi

  # Provision the certificate. The --webroot attempt used to omit -d/
  # --email/--non-interactive/--agree-tos entirely, so it never actually
  # succeeded (certbot either prompts interactively or refuses outright
  # without a domain) — every provision silently fell through to
  # --standalone, which needs port 80 free and so conflicts with a proxy
  # that's already bound to it (strut#395).
  log "auto-ssl: provisioning cert for $domain..."
  # shellcheck disable=SC2029
  if ssh $ssh_opts "$vps_user@$vps_host" "
    certbot certonly --webroot \
      -w /var/www/certbot \
      --non-interactive --agree-tos \
      --email '$email' \
      -d '$domain' \
      2>/dev/null || \
    certbot certonly --standalone \
      --non-interactive --agree-tos \
      --email '$email' \
      -d '$domain' \
      2>&1
  " >/dev/null 2>&1; then
    ok "auto-ssl: certificate provisioned for $domain"
  else
    warn "auto-ssl: certbot failed for $domain (port 80 accessible? certbot installed?)"
  fi
}
