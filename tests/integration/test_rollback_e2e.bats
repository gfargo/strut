#!/usr/bin/env bats
# ==================================================
# tests/integration/test_rollback_e2e.bats — Rollback restores the real image
# ==================================================
# OSS-480 / #206 acceptance test: deploy image A, deploy image B (the "bad"
# release), `rollback`, assert the running container is back on A's image
# digest — not re-resolved from the now-mutated compose tag.
#
# The stack's compose file references a single MUTABLE local tag (the common
# real-world case, e.g. ":latest"). Between deploys we retag it to point at a
# different image, exactly like a registry `:latest` tag moving underneath a
# running deployment. If rollback just re-pulled/re-resolved the tag, it would
# redeploy the current (bad) image — the bug this ticket fixes.
#
# Lives in tests/integration/ for the same reason as test_e2e.bats: needs a
# real Docker daemon, gated to the dedicated integration CI job, not the
# standard `bats tests/` unit matrix.

_skip_without_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"
}

# Distinct range from test_e2e.bats's _pick_port to avoid collisions when
# both integration files run in the same job.
_pick_port() {
  echo $((19000 + (BASHPID % 900)))
}

setup_file() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export CLI_ROOT
  export STRUT_HOME="$CLI_ROOT"

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    return 0
  fi

  export RB_STACK="rb-e2e-$$-$(date +%s)"
  export RB_ENV="test"
  export RB_TAG="strut-rollback-e2e-$$:latest"
  export RB_PORT
  RB_PORT="$(_pick_port)"
  export RB_STACK_DIR="$CLI_ROOT/stacks/$RB_STACK"
  export RB_ENV_FILE="$CLI_ROOT/.${RB_ENV}.env"

  mkdir -p "$RB_STACK_DIR"

  # Single service on a mutable local tag — no registry involved, so
  # BUILD_MODE=none keeps deploy from ever attempting to pull/resolve it;
  # the only thing that ever moves the tag is the test itself.
  cat > "$RB_STACK_DIR/docker-compose.yml" <<EOF
services:
  web:
    image: ${RB_TAG}
    container_name: ${RB_STACK}-web
    ports:
      - "${RB_PORT}:80"
    restart: unless-stopped
EOF

  cat > "$RB_STACK_DIR/services.conf" <<EOF
SERVICE_WEB_NAME=web
SERVICE_WEB_PORT=${RB_PORT}
SERVICE_WEB_HEALTH_PATH=/
EOF

  : > "$RB_STACK_DIR/required_vars"

  cat > "$RB_ENV_FILE" <<EOF
REGISTRY_TYPE=none
BUILD_MODE=none
EOF

  # Two distinct images to alternate the mutable tag between ("A" and "B").
  docker pull nginx:alpine >/dev/null 2>&1 || true
  docker pull httpd:alpine >/dev/null 2>&1 || true
}

teardown_file() {
  [ -z "${RB_STACK_DIR:-}" ] && return 0

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker compose \
      --env-file "$RB_ENV_FILE" \
      --project-name "${RB_STACK}-${RB_ENV}" \
      -f "$RB_STACK_DIR/docker-compose.yml" \
      down --volumes --remove-orphans >/dev/null 2>&1 || true
    docker rm -f "${RB_STACK}-web" >/dev/null 2>&1 || true
    docker rmi "$RB_TAG" >/dev/null 2>&1 || true
  fi

  rm -rf "$RB_STACK_DIR"
  rm -f "$RB_ENV_FILE"
}

setup() { _skip_without_docker; }

# ── Acceptance: deploy A, deploy B, rollback → running digest == A ───────────
# One @test so the two 60s "waiting for services to start" deploy sleeps are
# paid once each, not multiplied across separate tests.

@test "e2e rollback: restores image A's digest after the mutable tag moved to B" {
  docker tag nginx:alpine "$RB_TAG"
  local digest_a
  digest_a="$(docker inspect --format '{{.Id}}' nginx:alpine)"
  [ -n "$digest_a" ]

  # Deploy image A.
  run "$CLI_ROOT/strut" "$RB_STACK" deploy --env "$RB_ENV" --skip-validation --no-lock
  [ "$status" -eq 0 ]

  local running_digest
  running_digest="$(docker inspect --format '{{.Image}}' "${RB_STACK}-web")"
  [ "$running_digest" = "$digest_a" ]

  # Move the mutable tag to a different image and deploy again — this is
  # "deploy image B, it's bad." The rollback snapshot taken during THIS
  # deploy (before the switch) is the one that should carry A's digest.
  docker tag httpd:alpine "$RB_TAG"
  local digest_b
  digest_b="$(docker inspect --format '{{.Id}}' httpd:alpine)"
  [ "$digest_b" != "$digest_a" ]

  run "$CLI_ROOT/strut" "$RB_STACK" deploy --env "$RB_ENV" --skip-validation --no-lock
  [ "$status" -eq 0 ]

  running_digest="$(docker inspect --format '{{.Image}}' "${RB_STACK}-web")"
  [ "$running_digest" = "$digest_b" ]

  # Roll back. The compose tag still resolves to B locally — a rollback that
  # merely re-resolved the tag would redeploy B. It must instead restore A.
  run "$CLI_ROOT/strut" "$RB_STACK" rollback --env "$RB_ENV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"health"* ]]

  running_digest="$(docker inspect --format '{{.Image}}' "${RB_STACK}-web")"
  [ "$running_digest" = "$digest_a" ]

  # The container itself must actually be serving traffic post-rollback.
  local code=""
  for _ in 1 2 3 4 5; do
    code="$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${RB_PORT}/" || true)"
    [ "$code" = "200" ] && break
    sleep 2
  done
  [ "$code" = "200" ]
}
