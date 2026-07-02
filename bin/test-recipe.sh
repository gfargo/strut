#!/usr/bin/env bash
# ==================================================
# test-recipe.sh — Smoke-test a strut recipe locally or against a real VPS
# ==================================================
# Scaffolds a recipe into a temp project, writes minimum-viable env values,
# validates the compose, and (optionally) deploys locally or to a remote
# host, curls a smoke endpoint, and tears down.
#
# Usage:
#   bin/test-recipe.sh <recipe> [--deploy] [--host <ip>] [--port <port>]
#                      [--user <u>] [--key <path>]
#
# Modes:
#   config-only (default)  — scaffold + compose config --quiet
#   --deploy               — also boot the stack (local unless --host given)
#   --host <ip>            — deploy to remote VPS over SSH via strut release
#
# Examples:
#   bin/test-recipe.sh minecraft
#   bin/test-recipe.sh nextcloud --deploy
#   bin/test-recipe.sh pihole --deploy --host 188.166.19.111 --user root --key ~/.ssh/deploy
#
# Exits non-zero on any failure. Always tears down what it started, even on
# error, unless STRUT_TEST_KEEP=1 is set.
set -euo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRUT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STRUT="$STRUT_ROOT/strut"

# ── Args ──────────────────────────────────────────────────────────────────
recipe=""
do_deploy=false
host=""
user="root"
key=""
port_offset=0  # bumped up for remote to avoid stomping on host services

while [ $# -gt 0 ]; do
  case "$1" in
    --deploy)          do_deploy=true; shift ;;
    --host)            host="$2"; shift 2 ;;
    --user)            user="$2"; shift 2 ;;
    --key)             key="$2"; shift 2 ;;
    --port-offset)     port_offset="$2"; shift 2 ;;
    --help|-h)         sed -n '1,30p' "$0"; exit 0 ;;
    -*)                echo "Unknown flag: $1" >&2; exit 2 ;;
    *)                 recipe="$1"; shift ;;
  esac
done

[ -n "$recipe" ] || { echo "Usage: $0 <recipe> [--deploy] [--host <ip>] [--user <u>] [--key <path>]" >&2; exit 2; }
[ -d "$STRUT_ROOT/templates/recipes/$recipe" ] || {
  echo "Unknown recipe: $recipe (available: $(ls "$STRUT_ROOT/templates/recipes/" | tr '\n' ' '))" >&2
  exit 2
}

# ── Colored logging ───────────────────────────────────────────────────────
_ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
_info() { printf '\033[36m→\033[0m %s\n' "$*"; }
_fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

# ── Env presets: minimum-viable values for each recipe ────────────────────
_env_preset() {
  case "$recipe" in
    static-site)
      cat <<EOF
DOMAIN=test.local
ACME_EMAIL=test@example.com
EOF
      ;;
    python-api)
      cat <<EOF
REGISTRY_TYPE=none
POSTGRES_PASSWORD=placeholder-pw
DATABASE_URL=postgresql://${stack}:placeholder-pw@postgres:5432/${stack}
EOF
      ;;
    next-postgres)
      cat <<EOF
REGISTRY_TYPE=none
POSTGRES_PASSWORD=placeholder-pw
DATABASE_URL=postgresql://${stack}:placeholder-pw@postgres:5432/${stack}
NEXTAUTH_SECRET=placeholder-secret-32-chars-long!
DOMAIN=test.local
ACME_EMAIL=test@example.com
EOF
      ;;
    minecraft)
      cat <<EOF
EULA=TRUE
MC_VERSION=LATEST
MC_MEMORY=1G
EOF
      ;;
    pihole)
      cat <<EOF
PIHOLE_PASSWORD=placeholder-pw
TZ=UTC
PIHOLE_DNS=1.1.1.1;1.0.0.1
EOF
      ;;
    nextcloud)
      cat <<EOF
POSTGRES_PASSWORD=placeholder-pw
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=placeholder-pw
NEXTCLOUD_TRUSTED_DOMAINS=localhost ${host:-}
EOF
      ;;
    jellyfin)
      cat <<EOF
TZ=UTC
MEDIA_PATH=./media
EOF
      ;;
    vaultwarden)
      cat <<EOF
ADMIN_TOKEN=placeholder-token
DOMAIN=https://vault.test.local
EOF
      ;;
    uptime-kuma)
      cat <<EOF
TZ=UTC
EOF
      ;;
    n8n)
      cat <<EOF
N8N_ENCRYPTION_KEY=placeholder-encryption-key-32chars
N8N_HOST=n8n.test.local
N8N_PROTOCOL=https
GENERIC_TIMEZONE=UTC
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=placeholder-pw
EOF
      ;;
    homeassistant)
      cat <<EOF
TZ=UTC
EOF
      ;;
    immich)
      cat <<EOF
DB_PASSWORD=placeholder-pw
UPLOAD_LOCATION=./immich-library
IMMICH_VERSION=release
DB_HOSTNAME=postgres
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
EOF
      ;;
    gitea)
      cat <<EOF
TZ=UTC
USER_UID=1000
USER_GID=1000
EOF
      ;;
    audiobookshelf)
      cat <<EOF
TZ=UTC
AUDIOBOOKS_PATH=./audiobooks
PODCASTS_PATH=./podcasts
EOF
      ;;
    wg-easy)
      cat <<EOF
WG_HOST=vpn.test.local
PASSWORD_HASH=\$\$2y\$\$10\$\$placeholder-bcrypt-hash-for-compose-validation
EOF
      ;;
    umami)
      cat <<EOF
POSTGRES_PASSWORD=placeholder-pw
APP_SECRET=placeholder-app-secret-32chars-long
EOF
      ;;
    paperless-ngx)
      cat <<EOF
PAPERLESS_SECRET_KEY=placeholder-secret-key-32chars-long
POSTGRES_PASSWORD=placeholder-pw
PAPERLESS_ADMIN_USER=admin
PAPERLESS_ADMIN_PASSWORD=placeholder-pw
PAPERLESS_OCR_LANGUAGE=eng
PAPERLESS_TIME_ZONE=UTC
CONSUME_PATH=./consume
EOF
      ;;
    ghost)
      cat <<EOF
MYSQL_PASSWORD=placeholder-pw
GHOST_URL=https://blog.test.local
GHOST_VERSION=5-alpine
EOF
      ;;
    valheim)
      cat <<EOF
SERVER_NAME=Test
WORLD_NAME=Dedicated
SERVER_PASS=changeme
SERVER_PUBLIC=false
EOF
      ;;
    factorio)
      cat <<EOF
FACTORIO_PORT=34197
SAVE_NAME=world
EOF
      ;;
    *)
      # Unknown recipe: emit an empty env; user should tune.
      : ;;
  esac
}

# ── Smoke checks: how do we verify each recipe is up? ─────────────────────
_smoke_check() {
  # $1 = host (localhost or remote IP), $2 = port
  local h="$1" p="$2"
  case "$recipe" in
    static-site|python-api|next-postgres|nextcloud)
      curl -sf -o /dev/null -w '%{http_code}\n' "http://$h:$p/" ;;
    minecraft)
      # Minecraft is a TCP protocol, not HTTP. Just check the port is open.
      timeout 5 bash -c "</dev/tcp/$h/$p" 2>/dev/null && echo "open" || echo "closed" ;;
    pihole)
      curl -sf -o /dev/null -w '%{http_code}\n' "http://$h:$p/admin/" ;;
    *)
      echo "no-smoke-check-defined" ;;
  esac
}

# ── Set up temp project ───────────────────────────────────────────────────
tmp_project="$(mktemp -d -t "strut-test-recipe.XXXXXX")"
trap '_teardown' EXIT

_teardown() {
  local rc=$?
  if [ "${STRUT_TEST_KEEP:-}" = "1" ]; then
    _info "STRUT_TEST_KEEP=1 — leaving $tmp_project intact"
    return $rc
  fi
  if $do_deploy && [ -n "${stack:-}" ]; then
    _info "Tearing down stack $stack..."
    (cd "$tmp_project" && STRUT_NO_TUI=1 STRUT_YES=1 "$STRUT" "$stack" stop --env test </dev/null >/dev/null 2>&1) || true
  fi
  rm -rf "$tmp_project"
  return $rc
}

printf 'DEFAULT_ORG=testorg\nREGISTRY_TYPE=none\nBANNER_TEXT=recipe-test\n' > "$tmp_project/strut.conf"

# Bring topology config into the project if remote deploy requested
if [ -n "$host" ]; then
  cat >> "$tmp_project/strut.conf" <<EOF

[hosts]
target = ${user}@${host}:22${key:+ ${key}}
EOF
fi

# Unique stack name per run so parallel runs don't stomp each other.
stack="t-${recipe//_/-}-$$"
_info "Scaffolding $recipe into stack '$stack' at $tmp_project"

pushd "$tmp_project" >/dev/null
STRUT_NO_TUI=1 STRUT_YES=1 "$STRUT" scaffold "$stack" --recipe "$recipe" </dev/null >/dev/null

# Write env
_env_preset > "stacks/$stack/.env.template"  # keep template consistent
_env_preset > ".test.env"
_ok "Scaffold OK"

# ── Stage 1: compose config validation (fast, always runs) ────────────────
if ! docker compose --env-file .test.env -f "stacks/$stack/docker-compose.yml" config --quiet; then
  _fail "compose config failed"; exit 1
fi
_ok "compose config validates"

# ── Stage 2: deploy (optional) ────────────────────────────────────────────
if ! $do_deploy; then
  _ok "Recipe '$recipe' looks good (config-only mode). Use --deploy to boot it."
  exit 0
fi

# Pick a smoke-check port for each recipe. For remote deploys, we deliberately
# choose high ports (18000+) so we can't collide with anything the target
# host is already serving on 80/443.
_smoke_port() {
  case "$recipe" in
    minecraft)   echo "$((25565 + port_offset))" ;;
    pihole)      echo "$((18054 + port_offset))" ;;  # avoid host DNS if any
    static-site) echo "$((18080 + port_offset))" ;;
    nextcloud)   echo "$((18080 + port_offset))" ;;
    python-api)  echo "$((18000 + port_offset))" ;;
    next-postgres) echo "$((18080 + port_offset))" ;;
    *)           echo "$((18000 + port_offset))" ;;
  esac
}
smoke_port="$(_smoke_port)"

if [ -n "$host" ]; then
  # Remote deploy path via strut release. Requires target VPS to have
  # Docker + strut installed (bootstrap once with `strut remote:init`).
  _info "Remote deploy to $user@$host — using 'target' topology alias"
  # The remote 'release' command requires the deploy target to be bootstrapped.
  # For the smoke-test we short-circuit and just `strut … deploy` (local mode
  # would run against local Docker, so we ssh + docker compose instead).
  _fail "Remote --host mode: full remote deploy not yet automated in this script."
  _fail "For now, run: strut $stack release --env test --host target (after remote:init)."
  exit 3
fi

# Local deploy
_info "Local deploy: strut $stack deploy --env test"
STRUT_NO_TUI=1 STRUT_YES=1 "$STRUT" "$stack" deploy --env test --skip-validation --no-lock </dev/null

# Smoke check: keep trying for 60s while images pull / containers start.
_info "Smoke check on localhost:$smoke_port"
result="fail"
for _ in $(seq 1 30); do
  code="$(_smoke_check "localhost" "$smoke_port" 2>/dev/null || echo "")"
  if [[ "$code" == "200" || "$code" == "302" || "$code" == "open" ]]; then
    result="ok"; break
  fi
  sleep 2
done

if [ "$result" = "ok" ]; then
  _ok "Smoke check PASSED (recipe '$recipe' is serving on :$smoke_port)"
else
  _fail "Smoke check FAILED after 60s (recipe '$recipe' did not respond on :$smoke_port)"
  docker ps --filter "label=com.docker.compose.project=${stack}-test" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' >&2 || true
  exit 1
fi

popd >/dev/null
_ok "Recipe '$recipe' end-to-end validated."
