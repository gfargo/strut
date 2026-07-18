#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_drift_images.bats — Tests for `drift images` (strut#382)
# ==================================================
# Three bugs fixed here:
#   1. Wrong project name — `docker compose ps -q` with no --project-name
#      infers the project from the compose file's directory ("<stack>"),
#      never the "<stack>-<env>" project a real strut deploy creates, so
#      it silently found nothing for every real deployment.
#   2. Multi-arch false positive — the first "digest" field in a manifest
#      LIST is a per-platform manifest digest, never equal to what was
#      actually pulled, so every multi-arch image (postgres, nginx,
#      redis, ...) was reported as DRIFT.
#   3. SSH failure read as "current" — `... || true` swallowed connection
#      failures, so an unreachable host silently reported clean.
#
# `ssh` is stubbed to run the remote script LOCALLY via `bash -c` (the
# last positional arg is always the remote command string) — this
# exercises the real embedded script logic, not just the outer function.
#
# Run:  bats tests/test_cmd_drift_images.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail()  { echo "FAIL: $1" >&2; return 1; }
  ok()    { echo "OK: $*"; }
  warn()  { echo "WARN: $*" >&2; }
  log()   { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error
  export RED="" GREEN="" YELLOW="" NC=""

  source "$CLI_ROOT/lib/cmd_drift_images.sh"

  mkdir -p "$TEST_TMP/stacks/demo"
  cat > "$TEST_TMP/stacks/demo/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx:alpine
EOF
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=vps.example.com
EOF

  export CLI_ROOT="$TEST_TMP"
}

teardown() { common_teardown; }

# ── _drift_images_project_name ───────────────────────────────────────────────

@test "_drift_images_project_name: resolves via resolve_compose_cmd, not the bare stack name" {
  resolve_compose_cmd() { echo "docker compose --project-name demo-prod -f x.yml"; }
  export -f resolve_compose_cmd

  run _drift_images_project_name "demo" "$TEST_TMP/.prod.env"
  [ "$status" -eq 0 ]
  [ "$output" = "demo-prod" ]
}

@test "_drift_images_project_name: falls back to the bare stack name if resolution fails" {
  resolve_compose_cmd() { return 1; }
  export -f resolve_compose_cmd

  run _drift_images_project_name "demo" "$TEST_TMP/.prod.env"
  [ "$status" -eq 0 ]
  [ "$output" = "demo" ]
}

# ── Local detection: --project-name is actually passed ─────────────────────

@test "_drift_images_detect: passes --project-name to docker compose ps (strut#382 bug 1)" {
  docker() {
    if [ "$1" = "compose" ]; then
      echo "docker $*" >> "$TEST_TMP/docker_calls"
      [[ "$*" == *"--project-name demo-prod"* ]] || return 1
      echo ""  # no running containers, but the call itself must succeed
      return 0
    fi
  }
  export -f docker

  run _drift_images_detect "demo" "false" "demo-prod"
  [ "$status" -eq 0 ]
  grep -q -- "--project-name demo-prod" "$TEST_TMP/docker_calls"
}

# ── Remote detection: end-to-end through the embedded SSH script ───────────

_stub_remote_ssh() {
  # Runs the "remote" script locally via bash -c — the last arg to ssh is
  # always the command string.
  ssh() { local cmd="${*: -1}"; bash -c "$cmd"; }
  export -f ssh
  build_ssh_opts() { echo ""; }
  export -f build_ssh_opts
}

@test "drift_images_remote: passes --project-name in the remote compose invocation (strut#382 bug 1)" {
  _stub_remote_ssh
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="$TEST_TMP"

  docker() {
    echo "docker $*" >> "$TEST_TMP/docker_calls"
    case "$1 $2" in
      "compose -f")
        [[ "$*" == *"--project-name demo-prod"* ]] || { echo "MISSING PROJECT NAME" >&2; return 1; }
        echo ""  # no containers
        return 0
        ;;
    esac
  }
  export -f docker

  run drift_images_remote "demo" "false" "demo-prod"
  [ "$status" -eq 0 ]
  grep -q -- "--project-name demo-prod" "$TEST_TMP/docker_calls"
}

@test "drift_images_remote: single-arch image with matching digest reports current" {
  _stub_remote_ssh
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="$TEST_TMP"

  export digest="sha256:$(printf 'a%.0s' $(seq 1 64))"
  docker() {
    case "$1 $2" in
      "compose -f") echo "c1" ;;
      "inspect --format") echo "nginx:alpine|nginx@$digest" ;;
      "manifest inspect") echo "{\"digest\":\"${digest#sha256:}\"}" ;;
      *) return 1 ;;
    esac
  }
  export -f docker

  run drift_images_remote "demo" "true" "demo-prod"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.images[0] | select(.status == "current")' >/dev/null
  [ "$(echo "$output" | jq -r '.drifted')" = "0" ]
}

@test "drift_images_remote: single-arch image with a mismatched digest reports drift" {
  _stub_remote_ssh
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="$TEST_TMP"

  export running="sha256:$(printf 'a%.0s' $(seq 1 64))"
  export registry_only="$(printf 'b%.0s' $(seq 1 64))"
  docker() {
    case "$1 $2" in
      "compose -f") echo "c1" ;;
      "inspect --format") echo "nginx:alpine|nginx@$running" ;;
      "manifest inspect") echo "{\"digest\":\"$registry_only\"}" ;;
      *) return 1 ;;
    esac
  }
  export -f docker

  run drift_images_remote "demo" "true" "demo-prod"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.drifted')" = "1" ]
  echo "$output" | jq -e '.images[0] | select(.status == "stale")' >/dev/null
}

@test "drift_images_remote: multi-arch manifest list without buildx reports unknown, NOT drift (strut#382 bug 2)" {
  _stub_remote_ssh
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="$TEST_TMP"

  export running="sha256:$(printf 'a%.0s' $(seq 1 64))"
  docker() {
    case "$1 $2" in
      "compose -f") echo "c1" ;;
      "inspect --format") echo "postgres:16|postgres@$running" ;;
      "manifest inspect") echo '{"manifests":[{"digest":"sha256:platformonlydigest"}]}' ;;
      "buildx version") return 1 ;;
      *) return 1 ;;
    esac
  }
  export -f docker

  run drift_images_remote "demo" "true" "demo-prod"
  # Must NOT report drift just because the platform-manifest digest
  # differs from the pulled RepoDigest — that comparison is never valid.
  [ "$(echo "$output" | jq -r '.drifted')" = "0" ]
  [ "$(echo "$output" | jq -r '.unknown')" = "1" ]
  echo "$output" | jq -e '.images[0] | select(.status == "unknown")' >/dev/null
}

@test "drift_images_remote: multi-arch manifest list WITH buildx compares the true list digest" {
  _stub_remote_ssh
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="$TEST_TMP"

  # Named "fixture_" to avoid colliding with the production script's own
  # unqualified `list_digest` variable — both run in the same spawned
  # bash process (no function-local scoping across the ssh/bash -c
  # boundary), so a same-named fixture var gets clobbered mid-script.
  export fixture_list_digest="sha256:$(printf 'c%.0s' $(seq 1 64))"
  docker() {
    case "$1 $2" in
      "compose -f") echo "c1" ;;
      "inspect --format") echo "postgres:16|postgres@$fixture_list_digest" ;;
      "manifest inspect") echo '{"manifests":[{"digest":"sha256:platformonlydigest"}]}' ;;
      "buildx version") return 0 ;;
      "buildx imagetools") echo "Digest: $fixture_list_digest" ;;
      *) return 1 ;;
    esac
  }
  export -f docker

  run drift_images_remote "demo" "true" "demo-prod"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.drifted')" = "0" ]
  echo "$output" | jq -e '.images[0] | select(.status == "current")' >/dev/null
}

@test "drift_images_remote: digest-pinned refs (@sha256:) are already locked, reported current without a lookup" {
  _stub_remote_ssh
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="$TEST_TMP"

  docker() {
    case "$1 $2" in
      "compose -f") echo "c1" ;;
      "inspect --format") echo "nginx@sha256:pinned0000000000000000000000000000000000000000000000000000|nginx@sha256:pinned0000000000000000000000000000000000000000000000000000" ;;
      "manifest inspect") echo "SHOULD_NOT_BE_CALLED" ;;
      *) echo "SHOULD_NOT_BE_CALLED"; return 1 ;;
    esac
  }
  export -f docker

  run drift_images_remote "demo" "true" "demo-prod"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
  echo "$output" | jq -e '.images[0] | select(.status == "current")' >/dev/null
}

# ── SSH/deploy-dir failure — must error, never read as "current" ───────────

@test "drift_images_remote: SSH connection failure (rc 255) returns error, not clean (strut#382 bug 3)" {
  ssh() { return 255; }
  export -f ssh
  build_ssh_opts() { echo ""; }
  export -f build_ssh_opts
  export VPS_HOST="vps.example.com"

  run drift_images_remote "demo" "false" "demo-prod"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Could not reach"* ]]
}

@test "drift_images_remote: unresolvable deploy dir returns error, not clean" {
  _stub_remote_ssh
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="/definitely/does/not/exist/anywhere"

  run drift_images_remote "demo" "false" "demo-prod"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Could not reach"* ]]
}

@test "drift_images_remote: fails cleanly (not silently) when VPS_HOST is unset" {
  unset VPS_HOST
  run drift_images_remote "demo" "false" "demo-prod"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VPS_HOST not set"* ]]
}
