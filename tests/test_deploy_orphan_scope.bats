#!/usr/bin/env bats
# ==================================================
# tests/test_deploy_orphan_scope.bats — Orphan container reclaim is project-scoped (OSS-413 / strut#246)
# ==================================================
# Covers:
#   - _deploy_reclaim_named_containers removes a container owned by the
#     current project
#   - it leaves a same-named container owned by a DIFFERENT project alone
#     (and warns instead of removing it)
#   - it is a no-op when the named container does not exist

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
}

teardown() {
  common_teardown
}

_load_deploy() {
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/deploy.sh"
  warn() { echo "WARN: $*"; }
}

_make_compose_file() {
  local path="$TEST_TMP/docker-compose.yml"
  cat > "$path" <<'EOF'
services:
  app:
    image: example/app:latest
    container_name: myapp-web-1
EOF
  echo "$path"
}

# _stub_docker <owner_label>
#
# Stubs `docker` so `inspect <name>` succeeds (container "exists") and
# `inspect --format ...` reports the given owner label. `rm -f` calls are
# appended to $TEST_TMP/rm_calls for assertion.
_stub_docker_existing() {
  local owner_label="$1"
  # shellcheck disable=SC2317
  docker() {
    case "$1" in
      inspect)
        if [[ "$*" == *"--format"* ]]; then
          echo "$DOCKER_STUB_OWNER"
          return 0
        fi
        return 0
        ;;
      rm)
        echo "$*" >> "$TEST_TMP/rm_calls"
        return 0
        ;;
    esac
  }
  export DOCKER_STUB_OWNER="$owner_label"
  export -f docker
}

_stub_docker_missing() {
  # shellcheck disable=SC2317
  docker() {
    case "$1" in
      inspect) return 1 ;;
      rm) echo "$*" >> "$TEST_TMP/rm_calls"; return 0 ;;
    esac
  }
  export -f docker
}

@test "_deploy_reclaim_named_containers: removes a container owned by the current project" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  _stub_docker_existing "myapp-prod"

  run _deploy_reclaim_named_containers "$compose_file" "myapp-prod"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/rm_calls" ]
  grep -q "myapp-web-1" "$TEST_TMP/rm_calls"
}

@test "_deploy_reclaim_named_containers: leaves a container owned by a different project alone and warns" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  _stub_docker_existing "myapp-staging"

  run _deploy_reclaim_named_containers "$compose_file" "myapp-prod"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/rm_calls" ]
  [[ "$output" == *"myapp-web-1"* ]]
  [[ "$output" == *"myapp-staging"* ]]
  [[ "$output" == *"not removing"* ]]
}

@test "_deploy_reclaim_named_containers: no-op when the named container does not exist" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  _stub_docker_missing

  run _deploy_reclaim_named_containers "$compose_file" "myapp-prod"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/rm_calls" ]
}
