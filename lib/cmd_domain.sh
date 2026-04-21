#!/usr/bin/env bash
# ==================================================
# cmd_domain.sh — Domain/SSL command thin router
# ==================================================
# Forwards CMD_* context variables to domain_command() in lib/domain/cmd.sh.

set -euo pipefail

DOMAIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/domain"
[ -f "$DOMAIN_LIB_DIR/cmd.sh" ] && source "$DOMAIN_LIB_DIR/cmd.sh"

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

# cmd_domain [domain] [email] [--skip-ssl] (reads CMD_*)
cmd_domain() {
  domain_command \
    "$CMD_STACK" \
    "$CMD_ENV_FILE" \
    "$CMD_ENV_NAME" \
    "$@"
}
