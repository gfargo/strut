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

# ── _deploy_guard_project_collision (strut#418) ─────────────────────────────
# Two unrelated stacks sharing a Compose project name (typically via a
# shared env file's COMPOSE_PROJECT_NAME) let `down/up --remove-orphans`
# delete a sibling stack's live containers. The guard detects this by
# comparing each running container's working_dir label against the compose
# file about to be deployed.

# _stub_docker_ps_rows <rows>
# Stubs `docker ps -a --filter ... --format '{{.Names}}|{{.Label ...}}'` to
# emit the given newline-separated "name|working_dir" rows.
_stub_docker_ps_rows() {
  local rows="$1"
  # shellcheck disable=SC2317
  docker() {
    case "$1" in
      ps) printf '%s' "$DOCKER_STUB_ROWS" ;;
      *) return 0 ;;
    esac
  }
  export DOCKER_STUB_ROWS="$rows"
  export -f docker
}

@test "_deploy_guard_project_collision: no containers under the project — passes" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  _stub_docker_ps_rows ""

  run _deploy_guard_project_collision "$compose_file" "myapp-prod"
  [ "$status" -eq 0 ]
}

@test "_deploy_guard_project_collision: containers all belong to this stack's own compose file — passes" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  local own_dir; own_dir=$(dirname "$compose_file")
  _stub_docker_ps_rows "myapp-web-1|$own_dir"

  run _deploy_guard_project_collision "$compose_file" "myapp-prod"
  [ "$status" -eq 0 ]
}

@test "_deploy_guard_project_collision: a container from a different working_dir aborts with diagnostics" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  _stub_docker_ps_rows "octoprint-1|/home/gfargo/strut/stacks/octoprint"

  run _deploy_guard_project_collision "$compose_file" "observability"
  [ "$status" -eq 1 ]
  [[ "$output" == *"octoprint-1"* ]]
  [[ "$output" == *"/home/gfargo/strut/stacks/octoprint"* ]]
  [[ "$output" == *"observability"* ]]
  [[ "$output" == *"COMPOSE_PROJECT_NAME"* ]]
}

@test "_deploy_guard_project_collision: lists only the foreign containers, not the stack's own" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  local own_dir; own_dir=$(dirname "$compose_file")
  _stub_docker_ps_rows "myapp-web-1|$own_dir
octoprint-1|/home/gfargo/strut/stacks/octoprint"

  run _deploy_guard_project_collision "$compose_file" "myapp-prod"
  [ "$status" -eq 1 ]
  [[ "$output" == *"octoprint-1"* ]]
  [[ "$output" != *"myapp-web-1 (from"* ]]
}

@test "_deploy_guard_project_collision: a container with no working_dir label is not flagged (unknown, not foreign)" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  _stub_docker_ps_rows "legacy-container|"

  run _deploy_guard_project_collision "$compose_file" "myapp-prod"
  [ "$status" -eq 0 ]
}

@test "_deploy_guard_project_collision: docker query failure fails open (does not block deploy)" {
  _load_deploy
  local compose_file; compose_file=$(_make_compose_file)
  # shellcheck disable=SC2317
  docker() { return 1; }
  export -f docker

  run _deploy_guard_project_collision "$compose_file" "myapp-prod"
  [ "$status" -eq 0 ]
}

# ── deploy_stack: guard is actually wired in before the destructive step ────

@test "deploy_stack --dry-run: aborts before previewing teardown when a foreign container collides" {
  _load_deploy
  export CLI_ROOT="$TEST_TMP"
  local stack="myapp"
  local stack_dir="$TEST_TMP/stacks/$stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/docker-compose.yml" <<'EOF'
services:
  web:
    image: example/app:latest
EOF
  local env_file="$TEST_TMP/.prod.env"
  echo "COMPOSE_PROJECT_NAME=observability" > "$env_file"

  # shellcheck disable=SC2317
  docker() {
    case "$1" in
      compose)
        [[ "$*" == *"version"* ]] && return 0
        return 0
        ;;
      ps) echo "octoprint-1|/home/gfargo/strut/stacks/octoprint" ;;
      *) return 0 ;;
    esac
  }
  export -f docker
  deploy_run_pre_deploy_validation() { return 0; }
  export -f deploy_run_pre_deploy_validation
  deploy_prepare() { return 0; }
  export -f deploy_prepare
  load_services_conf() { return 0; }
  export -f load_services_conf
  print_banner() { :; }
  export -f print_banner

  DRY_RUN=true
  run deploy_stack "$stack" "$env_file" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"octoprint-1"* ]]
  [[ "$output" != *"Stop existing containers"* ]]
  [[ "$output" != *"No changes made"* ]]
}

@test "deploy_stack --dry-run: proceeds through the full plan when there's no collision" {
  _load_deploy
  export CLI_ROOT="$TEST_TMP"
  local stack="myapp"
  local stack_dir="$TEST_TMP/stacks/$stack"
  mkdir -p "$stack_dir"
  cat > "$stack_dir/docker-compose.yml" <<'EOF'
services:
  web:
    image: example/app:latest
EOF
  local env_file="$TEST_TMP/.prod.env"
  : > "$env_file"

  # shellcheck disable=SC2317
  docker() {
    case "$1" in
      compose) return 0 ;;
      ps) : ;; # no containers under this project — nothing to collide with
      *) return 0 ;;
    esac
  }
  export -f docker
  deploy_run_pre_deploy_validation() { return 0; }
  export -f deploy_run_pre_deploy_validation
  deploy_prepare() { return 0; }
  export -f deploy_prepare
  load_services_conf() { return 0; }
  export -f load_services_conf
  print_banner() { :; }
  export -f print_banner

  DRY_RUN=true
  run deploy_stack "$stack" "$env_file" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stop existing containers"* ]]
  [[ "$output" == *"No changes made"* ]]
}
