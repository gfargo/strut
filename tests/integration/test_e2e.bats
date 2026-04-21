#!/usr/bin/env bats
# ==================================================
# tests/integration/test_e2e.bats — End-to-end deploy lifecycle
# ==================================================
# Runs `strut <stack> deploy`, `stop`, and rollback against a real Docker
# daemon using a minimal nginx:alpine stack. Skips the file if Docker is
# unavailable, so it's safe to run on any dev machine; gated by a separate
# CI job (.github/workflows/integration.yml) that provisions Docker.
#
# This lives in tests/integration/ (not tests/) so the standard
# `bats tests/` CI job does not pick it up — that job has no Docker and
# these tests would be skipped anyway. Run locally with:
#   bats tests/integration/
#
# The test creates one stack under $CLI_ROOT/stacks/<stack>/ and one env
# file at $CLI_ROOT/.<env>.env (both gitignored). teardown_file brings the
# stack down with --volumes and removes the temp files.

_skip_without_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"
}

# Pick a free-ish port deterministically per PID to avoid collisions when
# the suite is run in parallel (e.g. bats --jobs). Range 18000-19000 keeps
# us well away from common dev services.
_pick_port() {
  echo $((18000 + (BASHPID % 1000)))
}

setup_file() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export CLI_ROOT
  export STRUT_HOME="$CLI_ROOT"

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    # Nothing to set up — per-test setup will skip.
    return 0
  fi

  # Unique stack name per file run (PID + epoch) so concurrent runs don't
  # stomp each other. Kept short enough that docker's container name
  # limits don't bite.
  export E2E_STACK="e2e-$$-$(date +%s)"
  export E2E_ENV="test"
  export E2E_PORT
  E2E_PORT="$(_pick_port)"
  export E2E_STACK_DIR="$CLI_ROOT/stacks/$E2E_STACK"
  export E2E_ENV_FILE="$CLI_ROOT/.${E2E_ENV}.env"

  mkdir -p "$E2E_STACK_DIR"

  # Minimal one-service stack — nginx:alpine starts in <1s and responds on /.
  # Service is named "web" (not "nginx") so the post-deploy reverse-proxy
  # reload check finds no match and skips cleanly.
  cat > "$E2E_STACK_DIR/docker-compose.yml" <<EOF
services:
  web:
    image: nginx:alpine
    container_name: ${E2E_STACK}-web
    ports:
      - "${E2E_PORT}:80"
    restart: unless-stopped
EOF

  cat > "$E2E_STACK_DIR/services.conf" <<EOF
SERVICE_WEB_NAME=web
SERVICE_WEB_PORT=${E2E_PORT}
SERVICE_WEB_HEALTH_PATH=/
EOF

  # Empty required_vars so deploy's per-stack validation is a no-op.
  : > "$E2E_STACK_DIR/required_vars"

  # Env file must exist and be non-empty for validate_env_file.
  # REGISTRY_TYPE=none skips registry auth.
  cat > "$E2E_ENV_FILE" <<EOF
REGISTRY_TYPE=none
EOF
}

teardown_file() {
  [ -z "${E2E_STACK_DIR:-}" ] && return 0

  # Best-effort teardown — tests may have partially succeeded.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker compose \
      --env-file "$E2E_ENV_FILE" \
      --project-name "${E2E_STACK}-${E2E_ENV}" \
      -f "$E2E_STACK_DIR/docker-compose.yml" \
      down --volumes --remove-orphans >/dev/null 2>&1 || true

    # Belt-and-suspenders: nuke by container_name in case compose project
    # metadata drifted.
    docker rm -f "${E2E_STACK}-web" >/dev/null 2>&1 || true
  fi

  rm -rf "$E2E_STACK_DIR"
  rm -f "$E2E_ENV_FILE"
}

setup() { _skip_without_docker; }

# ── 1. Compose syntax ─────────────────────────────────────────────────────────

@test "e2e: docker compose config validates for the minimal stack" {
  run docker compose \
    --env-file "$E2E_ENV_FILE" \
    -f "$E2E_STACK_DIR/docker-compose.yml" \
    config --quiet
  [ "$status" -eq 0 ]
}

# ── 2. Deploy brings the stack up + health check + rollback snapshot ──────────
# Combined into one @test so the 60s "Waiting for services to start" sleep
# in deploy_stack is paid once per file. Splitting would multiply wall time
# with no additional signal.

@test "e2e: strut deploy brings up the stack, serves HTTP, and saves a rollback snapshot" {
  run "$CLI_ROOT/strut" "$E2E_STACK" deploy --env "$E2E_ENV" --skip-validation --no-lock
  [ "$status" -eq 0 ]

  # The container should be running under the expected compose project.
  run docker ps \
    --filter "label=com.docker.compose.project=${E2E_STACK}-${E2E_ENV}" \
    --filter "status=running" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"${E2E_STACK}-web"* ]]

  # nginx responds 200 on /. Retry a few times in case the hardcoded
  # deploy sleep still hasn't given the container enough time.
  local code=""
  for _ in 1 2 3 4 5; do
    code="$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${E2E_PORT}/" || true)"
    [ "$code" = "200" ] && break
    sleep 2
  done
  [ "$code" = "200" ]

  # Rollback snapshot file was written.
  [ -d "$E2E_STACK_DIR/.rollback" ]
  run bash -c 'ls -1 "'"$E2E_STACK_DIR"'/.rollback"/*.json 2>/dev/null | wc -l'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tr -d ' ')" -ge 1 ]
}

# ── 3. Stop tears everything down ─────────────────────────────────────────────

@test "e2e: strut stop removes containers for the project" {
  run "$CLI_ROOT/strut" "$E2E_STACK" stop --env "$E2E_ENV"
  [ "$status" -eq 0 ]

  run docker ps \
    --filter "label=com.docker.compose.project=${E2E_STACK}-${E2E_ENV}" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
