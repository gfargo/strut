#!/usr/bin/env bash
# ==================================================
# lib/cmd_scaffold.sh — Scaffold a new stack
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Provides:
#   cmd_scaffold <new-stack-name>

set -euo pipefail

cmd_scaffold() {
  local new_name="${1:-}"
  [ -n "$new_name" ] || fail "Usage: strut scaffold <new-stack-name>"

  local target
  if [ -n "${PROJECT_ROOT:-}" ]; then
    target="$PROJECT_ROOT/stacks/$new_name"
  else
    target="$CLI_ROOT/stacks/$new_name"
  fi
  [ -d "$target" ] && fail "Stack already exists: $target"

  local templates_dir="${STRUT_HOME:-$CLI_ROOT}/templates"
  [ -d "$templates_dir" ] || fail "templates/ directory not found"

  log "Scaffolding new stack: $new_name → $target"
  mkdir -p "$target"

  # Copy template env
  [ -f "$templates_dir/env.template" ] && cp "$templates_dir/env.template" "$target/.env.template"

  # Copy template docker-compose files
  [ -f "$templates_dir/docker-compose.prod.yml" ] && cp "$templates_dir/docker-compose.prod.yml" "$target/docker-compose.yml"
  [ -f "$templates_dir/docker-compose.dev.yml" ]  && cp "$templates_dir/docker-compose.dev.yml"  "$target/docker-compose.dev.yml"

  # Generate services.conf skeleton from template
  if [ -f "$templates_dir/services.conf.template" ]; then
    cp "$templates_dir/services.conf.template" "$target/services.conf"
  fi

  # Generate required_vars from env.template keys
  if [ -f "$target/.env.template" ]; then
    grep -E '^[A-Z_]+=.' "$target/.env.template" \
      | sed 's/=.*//' \
      > "$target/required_vars"
  fi

  # Create reverse proxy placeholder based on REVERSE_PROXY config
  local proxy="${REVERSE_PROXY:-nginx}"
  case "$proxy" in
    nginx)
      mkdir -p "$target/nginx/conf.d"
      cat > "$target/nginx/nginx.conf" <<'NGINX_EOF'
user  nginx;
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;
events { worker_connections 1024; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    /var/log/nginx/access.log;
    sendfile      on;
    keepalive_timeout 65;
    include /etc/nginx/conf.d/*.conf;
}
NGINX_EOF
      ;;
    caddy)
      mkdir -p "$target/caddy"
      cat > "$target/caddy/Caddyfile" <<'CADDY_EOF'
# Caddyfile — reverse proxy configuration
# See https://caddyserver.com/docs/caddyfile
{
    # Global options
}

# :80 {
#     reverse_proxy app:8000
# }
CADDY_EOF
      ;;
  esac

  # Create sql/init placeholder
  mkdir -p "$target/sql/init"
  touch "$target/sql/init/.gitkeep"

  # Create backup.conf
  cat > "$target/backup.conf" <<'BACKUP_EOF'
BACKUP_SCHEDULE_POSTGRES="0 2 * * *"
BACKUP_RETAIN_DAYS=30
BACKUP_RETAIN_COUNT=10
BACKUP_POSTGRES=true
BACKUP_NEO4J=false
BACKUP_LOCAL_DIR="./backups"
BACKUP_EOF

  # Substitute stack name in files
  if command -v sed &>/dev/null; then
    find "$target" -type f -not -path '*/.git/*' -print0 | \
      xargs -0 sed -i.bak "s/STACK_NAME_PLACEHOLDER/$new_name/g" 2>/dev/null
    # Substitute DEFAULT_ORG into templates when set
    if [ -n "${DEFAULT_ORG:-}" ]; then
      find "$target" -type f -not -path '*/.git/*' -print0 | \
        xargs -0 sed -i.bak "s/YOUR_ORG/${DEFAULT_ORG}/g" 2>/dev/null
    fi
    find "$target" -name "*.bak" -delete 2>/dev/null
  fi

  ok "Stack scaffolded: $target"
  echo ""
  echo "Next steps:"
  echo "  1. Edit $target/.env.template → copy to .prod.env and fill secrets"
  echo "  2. Edit $target/docker-compose.yml → add your services"
  echo "  3. Edit $target/services.conf → declare your service ports and DB flags"
  case "$proxy" in
    nginx) echo "  4. Edit $target/nginx/conf.d/ → add your reverse proxy config" ;;
    caddy) echo "  4. Edit $target/caddy/Caddyfile → configure your reverse proxy" ;;
  esac
  echo "  5. strut $new_name deploy --env prod"
  echo ""
}
