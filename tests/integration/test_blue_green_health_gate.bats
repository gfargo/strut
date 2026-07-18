#!/usr/bin/env bats
# ==================================================
# tests/integration/test_blue_green_health_gate.bats — Blue-green health gate
# ==================================================
# Acceptance test for #208 / OSS-478: the blue-green health gate must judge
# the NEW (green) color's own containers, not the still-live old color's
# host ports — and it must actually fail the deploy (leaving the old color
# running and undrained) when green crash-loops.
#
# The three defects from #208 (subshell-discarded verdicts, NDJSON parsing,
# localhost probes answered by the old color) were already fixed in
# 36a9374; this file is the real-Docker regression test the fix itself
# never shipped with.
#
# Lives in tests/integration/ (Docker required) — see tests/integration/test_e2e.bats
# for the sibling standard-deploy coverage and the rationale for this directory.
# Run locally with: bats tests/integration/

_skip_without_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"
}

# Resolves the host port Docker assigned to the "web" service's container
# port 80 for the given blue-green project. The compose fixture never pins
# a host port (both colors share one docker-compose.yml and would otherwise
# collide on a fixed mapping while running side by side), so this has to be
# looked up per-project after `up -d`.
_web_port() {
  local project="$1"
  local out
  out=$(docker compose --project-name "$project" -f "$BG_STACK_DIR/docker-compose.yml" port web 80 2>/dev/null | head -1)
  echo "${out##*:}"
}

setup_file() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export CLI_ROOT
  export STRUT_HOME="$CLI_ROOT"

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    # Nothing to set up — per-test setup will skip.
    return 0
  fi

  export BG_STACK="bg-$$-$(date +%s)"
  # Distinct from test_e2e.bats's ".test.env" — both files land in the same
  # $CLI_ROOT and could run in the same `bats tests/integration/` invocation.
  export BG_ENV="bgtest"
  export BG_STACK_DIR="$CLI_ROOT/stacks/$BG_STACK"
  export BG_ENV_FILE="$CLI_ROOT/.${BG_ENV}.env"
  export BG_BLUE_PROJECT="${BG_STACK}-${BG_ENV}-blue"
  export BG_GREEN_PROJECT="${BG_STACK}-${BG_ENV}-green"

  mkdir -p "$BG_STACK_DIR"

  # No container_name and no fixed host port: blue and green run as separate
  # compose projects off the SAME docker-compose.yml (that's the point of
  # blue-green), so a hardcoded name/port would collide the moment green
  # comes up alongside a still-live blue.
  cat > "$BG_STACK_DIR/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx:alpine
    ports:
      - "80"
    restart: unless-stopped
EOF

  cat > "$BG_STACK_DIR/services.conf" <<EOF
SERVICE_WEB_NAME=web
SERVICE_WEB_HEALTH_PATH=/
EOF

  : > "$BG_STACK_DIR/required_vars"

  cat > "$BG_ENV_FILE" <<EOF
REGISTRY_TYPE=none
EOF
}

teardown_file() {
  [ -z "${BG_STACK_DIR:-}" ] && return 0

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    for project in "$BG_BLUE_PROJECT" "$BG_GREEN_PROJECT"; do
      docker compose --project-name "$project" -f "$BG_STACK_DIR/docker-compose.yml" \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
    done
  fi

  rm -rf "$BG_STACK_DIR"
  rm -f "$BG_ENV_FILE"
}

setup() {
  _skip_without_docker
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/deploy_blue_green.sh"

  # Short timeout/drain so the crash-loop test doesn't pay the default 30s
  # gate timeout or 60s drain — the gate only needs a few failing polls.
  export BLUE_GREEN_HEALTH_TIMEOUT=12
  export BLUE_GREEN_DRAIN_OVERRIDE=0
}

# ── 1. First deploy establishes a live, healthy blue ──────────────────────────

@test "bg health gate: first deploy establishes a live, healthy blue" {
  run "$CLI_ROOT/strut" "$BG_STACK" deploy --env "$BG_ENV" --blue-green --skip-validation --no-lock
  [ "$status" -eq 0 ]

  run docker ps \
    --filter "label=com.docker.compose.project=${BG_BLUE_PROJECT}" \
    --filter "status=running" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  local port
  port="$(_web_port "$BG_BLUE_PROJECT")"
  [ -n "$port" ]

  local code=""
  for _ in 1 2 3 4 5; do
    code="$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" || true)"
    [ "$code" = "200" ] && break
    sleep 2
  done
  [ "$code" = "200" ]

  [ "$(_bg_read_state "$BG_STACK" "$BG_ENV")" = "blue" ]
}

# ── 2. Crash-looping green is rejected: blue stays up, green is torn down ─────

@test "bg health gate: crash-looping green is rejected, blue is left running and undrained" {
  # Mutate the SAME compose file to crash-loop the web service. This is the
  # blue->green flip attempt; blue is already live from the previous test.
  cat > "$BG_STACK_DIR/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx:alpine
    command: ["sh", "-c", "exit 1"]
    restart: always
    ports:
      - "80"
EOF

  run "$CLI_ROOT/strut" "$BG_STACK" deploy --env "$BG_ENV" --blue-green --skip-validation --no-lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"never became healthy"* || "$output" == *"green_unhealthy"* ]]

  # Blue: still running, never touched by the failed flip.
  run docker ps \
    --filter "label=com.docker.compose.project=${BG_BLUE_PROJECT}" \
    --filter "status=running" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  # Green: torn down (including volumes) by _bg_teardown_failed_color, not
  # left behind as a crash-looping orphan.
  run docker ps -a \
    --filter "label=com.docker.compose.project=${BG_GREEN_PROJECT}" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # State never flipped — blue is still the active color.
  [ "$(_bg_read_state "$BG_STACK" "$BG_ENV")" = "blue" ]

  # Blue is still serving (the closest proxy-observable signal available
  # without wiring an actual reverse proxy in this minimal fixture).
  local port
  port="$(_web_port "$BG_BLUE_PROJECT")"
  [ -n "$port" ]
  run curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

# ── 3. A healthy second deploy actually flips blue → green, drains blue ───────
# Closes the real coverage gap OSS-399 called out: the two tests above only
# prove the REJECT path against a real daemon (crash-looping green). Nothing
# proved the successful promote+drain pipeline actually works end-to-end.
# This picks up right where test 2 left off (blue still live, state=blue).

@test "bg health gate: healthy second deploy flips blue to green, drains blue, fires proxy hook" {
  # Revert the fixture back to the healthy image (undo test 2's crash-loop).
  cat > "$BG_STACK_DIR/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx:alpine
    ports:
      - "80"
    restart: unless-stopped
EOF

  # No-op proxy hook so the swap step exercises the pluggable-hook path
  # (same contract already unit-tested by _bg_swap_proxy in
  # tests/test_deploy_blue_green.bats:320) instead of the built-in nginx
  # reload fallback, which this minimal fixture has no proxy service for.
  local hook_dir hook
  hook_dir="$(mktemp -d)"
  hook="$hook_dir/proxy-hook.sh"
  cat > "$hook" <<'EOF'
bluegreen_proxy_swap() {
  echo "proxy hook swap: stack=$1 old=$2 new=$3"
}
EOF
  export BLUE_GREEN_PROXY_HOOK="$hook"

  # Short drain so the test doesn't pay the default 60s.
  export BLUE_GREEN_DRAIN_OVERRIDE=1

  run "$CLI_ROOT/strut" "$BG_STACK" deploy --env "$BG_ENV" --blue-green --skip-validation --no-lock
  [ "$status" -eq 0 ]
  [[ "$output" == *"proxy hook swap"* ]]
  [[ "$output" == *"stack=$BG_STACK"* ]]
  [[ "$output" == *"old=$BG_BLUE_PROJECT"* ]]
  [[ "$output" == *"new=$BG_GREEN_PROJECT"* ]]

  rm -rf "$hook_dir"

  # State flipped from blue to green.
  [ "$(_bg_read_state "$BG_STACK" "$BG_ENV")" = "green" ]

  # Green is live and serving.
  run docker ps \
    --filter "label=com.docker.compose.project=${BG_GREEN_PROJECT}" \
    --filter "status=running" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  local green_port
  green_port="$(_web_port "$BG_GREEN_PROJECT")"
  [ -n "$green_port" ]
  local code=""
  for _ in 1 2 3 4 5; do
    code="$(curl -sf -o /dev/null -w '%{http_code}' "http://127.0.0.1:${green_port}/" || true)"
    [ "$code" = "200" ] && break
    sleep 2
  done
  [ "$code" = "200" ]

  # Blue is drained: stopped (not running)...
  run docker ps \
    --filter "label=com.docker.compose.project=${BG_BLUE_PROJECT}" \
    --filter "status=running" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # ...but NOT destroyed — _bg_stop_color uses `stop`, never `down`, so a
  # rollback can bring the same containers back on their original image.
  run docker ps -a \
    --filter "label=com.docker.compose.project=${BG_BLUE_PROJECT}" \
    --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
