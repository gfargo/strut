#!/usr/bin/env bash
# ==================================================
# lib/cmd_scaffold.sh — Scaffold a new stack
# ==================================================
# Requires: lib/utils.sh, lib/recipes.sh sourced first
#
# Provides:
#   cmd_scaffold <new-stack-name> [--recipe <recipe>]
#   cmd_scaffold list [--json]

set -euo pipefail

_usage_scaffold() {
  echo ""
  echo "Usage: strut scaffold <new-stack-name> [--recipe <recipe>]"
  echo "       strut scaffold list [--json]"
  echo ""
  echo "Create a new stack. Without --recipe, scaffolds the default"
  echo "single-service template (docker-compose, Dockerfile, services.conf,"
  echo "required_vars, proxy config). With --recipe <name> the recipe's"
  echo "files are copied instead."
  echo ""
  echo "Examples:"
  echo "  strut scaffold my-app"
  echo "  strut scaffold my-api --recipe python-api"
  echo "  strut scaffold list"
  echo "  strut scaffold list --json"
  echo ""
}

cmd_scaffold() {
  # ── Parse first positional ──────────────────────────
  local first="${1:-}"
  [ -n "$first" ] || fail "Usage: strut scaffold <new-stack-name> [--recipe <recipe>]"

  # ── Subcommand: list ────────────────────────────────
  if [ "$first" = "list" ]; then
    shift
    local want_json=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) want_json=true; shift ;;
        *) fail "Unknown flag: $1  (usage: strut scaffold list [--json])" ;;
      esac
    done
    recipes_discover
    if [ "$want_json" = "true" ] || [ "$(output_mode)" = "json" ]; then
      OUTPUT_MODE=json recipes_list_json
    else
      recipes_list_text
    fi
    return 0
  fi

  local new_name="$first"
  shift || true

  # ── Parse flags ─────────────────────────────────────
  local recipe_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recipe=*) recipe_flag="${1#*=}"; shift ;;
      --recipe)   recipe_flag="${2:-}"; shift 2 ;;
      *) fail "Unknown flag: $1  (usage: strut scaffold <name> [--recipe <recipe>])" ;;
    esac
  done

  local target
  if [ -n "${PROJECT_ROOT:-}" ]; then
    target="$PROJECT_ROOT/stacks/$new_name"
  else
    target="$CLI_ROOT/stacks/$new_name"
  fi
  [ -d "$target" ] && fail "Stack already exists: $target"

  local templates_dir="${STRUT_HOME:-$CLI_ROOT}/templates"
  [ -d "$templates_dir" ] || fail "templates/ directory not found"

  # ── Branch: recipe-driven scaffold ──────────────────
  if [ -n "$recipe_flag" ]; then
    recipes_discover
    local recipe_dir
    recipe_dir="$(recipes_dir_for "$recipe_flag")" || \
      fail "Unknown recipe: $recipe_flag  (run 'strut scaffold list' to see available recipes)"

    log "Scaffolding new stack from recipe '$recipe_flag': $new_name → $target"
    mkdir -p "$target"

    # Copy everything except recipe.conf.
    # tar pipe preserves hidden files (.gitignore etc.) and subdirs.
    ( cd "$recipe_dir" && tar --exclude=recipe.conf -cf - . ) | ( cd "$target" && tar -xf - )

    _scaffold_substitute "$target" "$new_name"

    ok "Stack scaffolded from recipe '$recipe_flag': $target"
    echo ""
    echo "Next steps:"
    if [ -f "$target/README.md" ]; then
      echo "  1. Read $target/README.md for recipe-specific guidance"
      echo "  2. Edit $target/.env.template → copy to .prod.env and fill secrets"
      echo "  3. strut $new_name deploy --env prod"
    else
      echo "  1. Edit $target/.env.template → copy to .prod.env and fill secrets"
      echo "  2. Edit $target/docker-compose.yml → review and adjust services"
      echo "  3. strut $new_name deploy --env prod"
    fi
    echo ""
    return 0
  fi

  # ── Default scaffold (backward compat, no recipe) ───
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

  # Generate anonymize.conf template
  cat > "$target/anonymize.conf" <<'ANON_EOF'
# ==================================================
# anonymize.conf — PII anonymization rules
# ==================================================
# Applied when syncing production data locally with --anonymize.
# Format: TABLE.COLUMN=strategy
#
# Strategies:
#   fake_email    Replace with user_<id>@example.com
#   fake_name     Replace with "User <id>"
#   null          Set to NULL
#   mask          Keep first/last char, mask middle with ***
#   hash          SHA256 hash (preserves uniqueness)
#   fake_address  Replace with generic address
#   preserve      Keep original value (explicit opt-in for non-PII)
#
# Examples:
# users.email=fake_email
# users.name=fake_name
# users.phone=null
# orders.address=fake_address
# payments.card_number=mask
ANON_EOF

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

  _scaffold_substitute "$target" "$new_name"

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

# _scaffold_substitute <target> <stack-name>
# Replaces STACK_NAME_PLACEHOLDER and YOUR_ORG (when DEFAULT_ORG set) across
# every file under <target>. Uses sed -i with a .bak suffix for BSD/GNU
# portability, then sweeps the .bak files.
_scaffold_substitute() {
  local target="$1" new_name="$2"
  command -v sed >/dev/null 2>&1 || return 0
  find "$target" -type f -not -path '*/.git/*' -print0 | \
    xargs -0 sed -i.bak "s/STACK_NAME_PLACEHOLDER/$new_name/g" 2>/dev/null
  if [ -n "${DEFAULT_ORG:-}" ]; then
    find "$target" -type f -not -path '*/.git/*' -print0 | \
      xargs -0 sed -i.bak "s/YOUR_ORG/${DEFAULT_ORG}/g" 2>/dev/null
  fi
  find "$target" -name "*.bak" -delete 2>/dev/null || true
}
