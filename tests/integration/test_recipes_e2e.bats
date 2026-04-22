#!/usr/bin/env bats
# ==================================================
# tests/integration/test_recipes_e2e.bats — Scaffold + compose + deploy per recipe
# ==================================================
# For each official recipe:
#   1. Scaffold via `strut scaffold <name> --recipe <r>`
#   2. Write a minimal env file from .env.template (placeholder values)
#   3. Run `docker compose config --quiet` on the scaffolded result
#
# Additionally for python-api (the only recipe that's reasonable to boot in
# CI — no TLS, no host 80/443 ports, has a real `/health` endpoint):
#   4. `strut <stack> deploy --env test --skip-validation --no-lock`
#   5. curl /health — verify 200 and that the service reaches Postgres
#   6. `strut <stack> stop`
#
# Lives under tests/integration/ so the main `bats tests/` job ignores it —
# the `.github/workflows/integration.yml` job is the one that provisions
# Docker and runs these.

_skip_without_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"
}

setup_file() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export CLI_ROOT
  export STRUT_HOME="$CLI_ROOT"

  # Track every stack we scaffold so teardown nukes them even if a test
  # aborts partway.
  export SCAFFOLDED_STACKS_FILE="$(mktemp)"
  : > "$SCAFFOLDED_STACKS_FILE"
}

teardown_file() {
  # Best-effort cleanup of anything we scaffolded or deployed.
  if [ -f "${SCAFFOLDED_STACKS_FILE:-}" ]; then
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      local stack="${entry%%|*}"
      local env="${entry##*|}"
      local stack_dir="$CLI_ROOT/stacks/$stack"
      local env_file="$CLI_ROOT/.${env}.env"

      if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && [ -f "$stack_dir/docker-compose.yml" ] && [ -f "$env_file" ]; then
        docker compose \
          --env-file "$env_file" \
          --project-name "${stack}-${env}" \
          -f "$stack_dir/docker-compose.yml" \
          down --volumes --remove-orphans >/dev/null 2>&1 || true
      fi

      # Belt and suspenders: strip containers by explicit name.
      for svc in api postgres web proxy; do
        docker rm -f "${stack}-${svc}" >/dev/null 2>&1 || true
      done

      rm -rf "$stack_dir"
      rm -f "$env_file"
    done < "$SCAFFOLDED_STACKS_FILE"
    rm -f "$SCAFFOLDED_STACKS_FILE"
  fi
}

_register_stack() {
  # _register_stack <stack> <env>
  echo "${1}|${2}" >> "$SCAFFOLDED_STACKS_FILE"
}

_scaffold_recipe() {
  # _scaffold_recipe <recipe> -> echoes the stack name on stdout
  #
  # DEFAULT_ORG is set here because the recipe templates reference
  # `YOUR_ORG/...` in the image field; without a substitution, docker
  # rejects the reference for containing uppercase letters. In production
  # users set DEFAULT_ORG in their strut.conf.
  local recipe="$1"
  local stack="e2e-${recipe}-$$-${BATS_TEST_NUMBER:-0}"
  _register_stack "$stack" "test"
  DEFAULT_ORG=testorg "$CLI_ROOT/strut" scaffold "$stack" --recipe "$recipe" >/dev/null 2>&1 || return 1
  echo "$stack"
}

setup() { _skip_without_docker; }

# ── 1. Compose config validates per recipe ───────────────────────────────────
# These don't bring containers up — they just parse the compose file with
# interpolated env. Catches YAML typos, broken references, unset vars, etc.

@test "recipes: static-site compose config validates with placeholder env" {
  local stack
  stack="$(_scaffold_recipe static-site)" || { echo "scaffold failed"; false; }
  local stack_dir="$CLI_ROOT/stacks/$stack"
  local env_file="$CLI_ROOT/.test.env"

  cat > "$env_file" <<EOF
DOMAIN=test.local
ACME_EMAIL=test@example.com
EOF

  run docker compose \
    --env-file "$env_file" \
    -f "$stack_dir/docker-compose.yml" \
    config --quiet
  [ "$status" -eq 0 ]
}

@test "recipes: python-api compose config validates with placeholder env" {
  local stack
  stack="$(_scaffold_recipe python-api)" || { echo "scaffold failed"; false; }
  local stack_dir="$CLI_ROOT/stacks/$stack"
  local env_file="$CLI_ROOT/.test.env"

  cat > "$env_file" <<EOF
POSTGRES_PASSWORD=placeholder-pw
DATABASE_URL=postgresql://${stack}:placeholder-pw@postgres:5432/${stack}
EOF

  run docker compose \
    --env-file "$env_file" \
    -f "$stack_dir/docker-compose.yml" \
    config --quiet
  [ "$status" -eq 0 ]
}

@test "recipes: next-postgres compose config validates with placeholder env" {
  local stack
  stack="$(_scaffold_recipe next-postgres)" || { echo "scaffold failed"; false; }
  local stack_dir="$CLI_ROOT/stacks/$stack"
  local env_file="$CLI_ROOT/.test.env"

  cat > "$env_file" <<EOF
POSTGRES_PASSWORD=placeholder-pw
DATABASE_URL=postgresql://${stack}:placeholder-pw@postgres:5432/${stack}
NEXTAUTH_SECRET=placeholder-secret
DOMAIN=test.local
ACME_EMAIL=test@example.com
EOF

  run docker compose \
    --env-file "$env_file" \
    -f "$stack_dir/docker-compose.yml" \
    config --quiet
  [ "$status" -eq 0 ]
}

# ── 2. Full E2E deploy of python-api ─────────────────────────────────────────
# This boots postgres + api, verifies the /health endpoint reaches Postgres,
# and tears down. The python image build adds ~30-60s to the run, so this
# is the slowest test in the suite — kept to one recipe on purpose.

@test "recipes: python-api full deploy → /health OK (Postgres reachable) → stop" {
  local stack
  stack="$(_scaffold_recipe python-api)" || { echo "scaffold failed"; false; }
  local stack_dir="$CLI_ROOT/stacks/$stack"
  local env_file="$CLI_ROOT/.test.env"

  cat > "$env_file" <<EOF
REGISTRY_TYPE=none
POSTGRES_PASSWORD=e2e-test-pw
DATABASE_URL=postgresql://${stack}:e2e-test-pw@postgres:5432/${stack}
EOF

  # deploy — skip validation (our placeholder password would trip the
  # weak-password scan) and skip locking (tmp stack, no concurrent access).
  run "$CLI_ROOT/strut" "$stack" deploy --env test --skip-validation --no-lock
  [ "$status" -eq 0 ]

  # Let postgres finish starting even if the deploy returned a bit early.
  local code=""
  for _ in $(seq 1 30); do
    code="$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:8000/health" || true)"
    [ "$code" = "200" ] && break
    sleep 2
  done
  [ "$code" = "200" ]

  # /health responds with {"status":"ok","db":"up"} on success.
  run curl -sf "http://127.0.0.1:8000/health"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"ok"'* ]]
  [[ "$output" == *'"db":"up"'* ]]

  # stop — confirm cleanup works through the normal code path.
  run "$CLI_ROOT/strut" "$stack" stop --env test
  [ "$status" -eq 0 ]

  run docker ps \
    --filter "label=com.docker.compose.project=${stack}-test" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
