#!/usr/bin/env bash
# ==================================================
# lib/deploy.sh — Deploy orchestration logic
# ==================================================
# Requires: lib/utils.sh, lib/docker.sh sourced first.
# Sources lib/fleet.sh automatically if fleet_sync is not already available.

# Source fleet.sh if not already loaded (provides fleet_sync used by vps_update_repo)
if ! declare -f fleet_sync >/dev/null 2>&1; then
  # shellcheck source=lib/fleet.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet.sh"
fi

# render_safe_clean_snippet <force_clean>
#
# Emits a remote-shell snippet (as a string) that performs a safe git clean:
#   1. Dry-run git clean -fdn to detect what would be removed.
#   2. If nothing: run git clean -fd normally.
#   3. If something and force_clean=true: run git clean -fd (operator override).
#   4. If something and force_clean=false: abort with guidance.
#
# Used by lib/migrate/phase-setup.sh for the migrate update path.
render_safe_clean_snippet() {
  local force_clean="${1:-false}"
  cat <<SNIPPET
__would_remove=\$(git clean -fdn)
if [ -n "\$__would_remove" ]; then
  if [ "$force_clean" = "true" ]; then
    git clean -fd
  else
    echo 'ERROR: git clean would delete untracked paths in the checkout:' >&2
    echo "\$__would_remove" >&2
    echo '' >&2
    echo 'These may be container data dirs or bind-mount sources living inside' >&2
    echo 'the checkout. Move data outside the repo or gitignore the paths, then' >&2
    echo 're-run. To override (data-loss risk), add --force-clean.' >&2
    exit 1
  fi
else
  git clean -fd
fi
SNIPPET
}

# _deploy_reclaim_named_containers <compose_file> <project_name>
#
# Force-removes any orphaned container with an explicit container_name in
# <compose_file> that docker compose down may have missed (e.g. from a
# previously failed deploy) — this prevents "name already in use" errors on
# restart. Only removes a container that is actually owned by <project_name>
# (per its com.docker.compose.project label); a same-named container owned by
# a different project/env is left alone with a warning, since force-removing
# it would kill another live deployment sharing the container_name.
_deploy_reclaim_named_containers() {
  local compose_file="$1"
  local project_name="$2"

  local orphaned_names
  orphaned_names=$(grep -E '^\s+container_name:\s*' "$compose_file" \
    | sed 's/.*container_name:\s*//' | tr -d '"' | tr -d "'" | xargs) || true
  [ -n "$orphaned_names" ] || return 0

  for cname in $orphaned_names; do
    docker inspect "$cname" &>/dev/null || continue
    local owner
    owner=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$cname" 2>/dev/null) || owner=""
    if [ "$owner" = "$project_name" ]; then
      docker rm -f "$cname" 2>/dev/null || true
    else
      warn "Container '$cname' exists but belongs to project '${owner:-<none>}' (expected '$project_name') — not removing."
    fi
  done
}

# _deploy_guard_project_collision <compose_file> <project_name>
#
# Detects a distinct footgun from the one above: two entirely different
# stacks resolving to the SAME Compose project name (most commonly because
# they share one env file with a hardcoded COMPOSE_PROJECT_NAME — env files
# are per-environment, not per-stack). Compose's orphan detection is
# project-scoped, not compose-file-scoped: `down --remove-orphans` / `up -d
# --remove-orphans` will delete ANY container labeled with that project that
# isn't a service in the compose file about to be deployed — including a
# completely unrelated sibling stack's live containers (strut#418).
#
# Every container Compose starts is labeled with the working directory of
# the compose file that created it (com.docker.compose.project.working_dir).
# Two unrelated stacks sharing a project name will have DIFFERENT working
# directories; a stack's own prior deploy will always match. That's the
# signal this checks: any running container under <project_name> whose
# working_dir doesn't match <compose_file>'s directory means the resolved
# project name is shared with another stack, and continuing would let
# --remove-orphans delete it.
_deploy_guard_project_collision() {
  local compose_file="$1"
  local project_name="$2"
  local expected_working_dir
  expected_working_dir="$(cd "$(dirname "$compose_file")" && pwd)"

  local rows
  rows=$(docker ps -a \
    --filter "label=com.docker.compose.project=$project_name" \
    --format '{{.Names}}|{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0

  local -a collisions=()
  local name working_dir
  while IFS='|' read -r name working_dir; do
    [ -n "$name" ] || continue
    if [ -n "$working_dir" ] && [ "$working_dir" != "$expected_working_dir" ]; then
      collisions+=("$name (from $working_dir)")
    fi
  done <<<"$rows"

  [ "${#collisions[@]}" -eq 0 ] && return 0

  error "Compose project '$project_name' already has containers from a DIFFERENT stack:"
  local c
  for c in "${collisions[@]}"; do
    echo "    - $c" >&2
  done
  echo "" >&2
  echo "  This stack's compose file is at: $expected_working_dir" >&2
  echo "" >&2
  echo "  The resolved project name is shared by more than one stack — usually" >&2
  echo "  because COMPOSE_PROJECT_NAME is set in an env file used by multiple" >&2
  echo "  stacks (env files are per-environment, not per-stack). Continuing" >&2
  echo "  would let 'docker compose down/up --remove-orphans' delete the" >&2
  echo "  containers listed above." >&2
  echo "" >&2
  echo "  Fix: give this stack its own env file (.<stack>-<env>.env, deployed" >&2
  echo "  with --env <stack>-<env>) so it resolves to a distinct project name," >&2
  echo "  or remove COMPOSE_PROJECT_NAME from the shared env file." >&2
  return 1
}

# _deploy_resolve_data_dirs
#
# Resolves which data directories deploy_stack should create for the stack
# currently being deployed. Reads STACK_DATA_DIRS and the DB_* flags from
# the environment — callers must load_services_conf first.
#
# Precedence (strut#417):
#   1. STACK_DATA_DIRS explicitly set, including to an empty string —
#      honoured verbatim. An empty value creates NO directories at all; use
#      this for stacks whose data dirs are managed externally or are
#      root-owned by the container. The no-colon ${var+x} test is what
#      distinguishes "explicitly set to empty" from "never set" —
#      ${STACK_DATA_DIRS:-default} treats both the same, which was the bug.
#   2. STACK_DATA_DIRS unset — derive from the same DB_* flags in
#      services.conf that health.sh reads, falling back to a single generic
#      "data" dir when none are set.
#
# Echoes a space-separated list of paths relative to the stack directory
# (possibly empty). Callers loop `for dir in $(...)`.
_deploy_resolve_data_dirs() {
  if [ -n "${STACK_DATA_DIRS+x}" ]; then
    echo "$STACK_DATA_DIRS"
    return 0
  fi

  local -a dirs=()
  [ "${DB_POSTGRES:-false}" = "true" ] && dirs+=("data/postgres")
  [ "${DB_REDIS:-false}" = "true" ]   && dirs+=("data/redis")
  [ "${DB_NEO4J:-false}" = "true" ]   && dirs+=("data/neo4j")
  [ "${DB_MYSQL:-false}" = "true" ]   && dirs+=("data/mysql")

  if [ "${#dirs[@]}" -eq 0 ]; then
    echo "data"
  else
    echo "${dirs[*]}"
  fi
}

# _docker_host_platform
#
# Echoes the local Docker daemon's native platform as "<os>/<arch>" (e.g.
# "linux/amd64", "linux/arm64") — used to decide whether a PLATFORMS build
# can stay on the plain `docker compose build` path. Empty on failure.
_docker_host_platform() {
  docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null
}

# _deploy_build_images <stack> <compose_cmd> <stack_dir>
#
# Builds images for the stack currently being deployed (BUILD_MODE=local),
# honoring the optional PLATFORMS var (services.conf, or exported by
# `rebuild --platform`) for cross-arch / multi-arch builds via buildx.
# Also fires the arch-mismatch pre-build warning (see
# _deploy_warn_arch_mismatch) whenever PLATFORMS is set, so both the
# `rebuild` and config-driven BUILD_MODE=local paths get it for free.
#
# Reads from the environment: BUILD_ARGS, BUILD_PULL, BUILD_PARALLEL,
# PLATFORMS (comma-separated docker platform list, e.g.
# "linux/amd64,linux/arm64"), REGISTRY_TYPE, REGISTRY_HOST.
#
# Three cases:
#   1. PLATFORMS unset, or a single platform equal to the host's native
#      platform → today's `$compose_cmd build` path. No buildx dependency,
#      so single-arch stacks and older Docker installs (some Pi images)
#      never need it.
#   2. PLATFORMS is a single platform different from the host's → cross-arch
#      build via `docker buildx bake --platform ... --load` (buildx CAN load
#      a single foreign platform into the local image store).
#   3. PLATFORMS lists more than one platform → multi-arch build via
#      `docker buildx bake --platform ... --push`. buildx cannot --load more
#      than one platform into the local daemon, so a multi-arch build must
#      push the resulting manifest to a registry — this requires
#      REGISTRY_TYPE/REGISTRY_HOST to already be configured (registry_login
#      must have already run), or it fails loudly rather than silently
#      building nothing usable.
_deploy_build_images() {
  local stack="$1"
  local compose_cmd="$2"
  local stack_dir="$3"
  local build_args="${BUILD_ARGS:-}"
  local platforms="${PLATFORMS:-}"

  [ -n "$platforms" ] && _deploy_warn_arch_mismatch "$stack" "$platforms"

  if [ -z "$platforms" ]; then
    local build_cmd="$compose_cmd build"
    [ "${BUILD_PULL:-false}" = "true" ] && build_cmd="$build_cmd --pull"
    [ "${BUILD_PARALLEL:-true}" = "true" ] && build_cmd="$build_cmd --parallel"
    [ -n "$build_args" ] && build_cmd="$build_cmd $build_args"
    $build_cmd
    return $?
  fi

  local -a platform_list
  IFS=',' read -ra platform_list <<< "$platforms"

  if [ "${#platform_list[@]}" -eq 1 ]; then
    local host_platform
    host_platform=$(_docker_host_platform)
    if [ "${platform_list[0]}" = "$host_platform" ]; then
      local build_cmd="$compose_cmd build"
      [ "${BUILD_PULL:-false}" = "true" ] && build_cmd="$build_cmd --pull"
      [ "${BUILD_PARALLEL:-true}" = "true" ] && build_cmd="$build_cmd --parallel"
      [ -n "$build_args" ] && build_cmd="$build_cmd $build_args"
      $build_cmd
      return $?
    fi
  fi

  # Cross-arch or multi-arch build → docker buildx (not a compose
  # subcommand, so this is a separate invocation against the compose file
  # rather than something appended to $compose_cmd).
  docker buildx version &>/dev/null \
    || fail "docker buildx is required for PLATFORMS='$platforms' but was not found (Docker Engine 20.10+ ships it by default)"

  local compose_file="$stack_dir/docker-compose.yml"
  local -a bake_args=(buildx bake -f "$compose_file" --set "*.platform=$platforms")
  # shellcheck disable=SC2206  # BUILD_ARGS is a space-separated flag list (e.g. "--no-cache --pull"), intentional word split
  [ -n "$build_args" ] && bake_args+=($build_args)

  if [ "${#platform_list[@]}" -gt 1 ]; then
    [ "${REGISTRY_TYPE:-none}" != "none" ] && [ -n "${REGISTRY_HOST:-}" ] \
      || fail "PLATFORMS='$platforms' builds more than one architecture, which requires --push to a registry — set REGISTRY_TYPE and REGISTRY_HOST first (buildx cannot load a multi-arch manifest into the local image store)."
    log "Building multi-arch images ($platforms) via buildx — pushing manifest to $REGISTRY_HOST..."
    docker "${bake_args[@]}" --push
  else
    log "Building for $platforms via buildx (host is ${host_platform:-unknown})..."
    docker "${bake_args[@]}" --load
  fi
}

# _deploy_warn_arch_mismatch <stack> <platforms>
#
# Best-effort pre-build warning (never blocks) when the platform(s) about to
# be built don't include the target host's CPU architecture — the classic
# "works on my amd64 laptop, exec format error on the Pi" failure. <platforms>
# is a PLATFORMS-style comma-separated list; a single "linux/amd64" also works.
#
# Target arch resolution order:
#   1. Declared `arch=` in the topology host spec (strut.conf [hosts]) — free.
#   2. Best-effort `uname -m` over SSH to VPS_HOST, mapped to Docker's arch
#      naming (x86_64→amd64, aarch64/arm64→arm64, armv7l→arm/v7).
#   3. Unknown (no VPS_HOST, unreachable host, no declared arch) → skip
#      silently; this is advisory, not a hard requirement.
_deploy_warn_arch_mismatch() {
  local stack="$1"
  local platforms="$2"
  [ -n "$platforms" ] || return 0

  local target_arch=""
  if declare -F topology_resolve_arch >/dev/null 2>&1; then
    target_arch=$(topology_resolve_arch "$stack" 2>/dev/null) || target_arch=""
  fi

  if [ -z "$target_arch" ] && [ -n "${VPS_HOST:-}" ]; then
    local vps_user="${VPS_USER:-ubuntu}"
    local vps_port="${VPS_PORT:-22}"
    local vps_ssh_key="${VPS_SSH_KEY:-}"
    local ssh_opts
    ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch 2>/dev/null) || return 0
    local remote_uname
    # shellcheck disable=SC2029
    remote_uname=$(timeout 5 ssh $ssh_opts "$vps_user@$VPS_HOST" "uname -m" 2>/dev/null) || return 0
    case "$remote_uname" in
      x86_64)        target_arch="amd64" ;;
      aarch64|arm64) target_arch="arm64" ;;
      armv7l)        target_arch="arm/v7" ;;
      "")            return 0 ;;
      *)             target_arch="$remote_uname" ;;
    esac
  fi

  [ -n "$target_arch" ] || return 0

  local -a platform_list
  IFS=',' read -ra platform_list <<< "$platforms"
  local plat covered=false
  for plat in "${platform_list[@]}"; do
    if [[ "$plat" == */"$target_arch" || "$plat" == */"$target_arch"/* ]]; then
      covered=true
      break
    fi
  done

  $covered && return 0
  warn "Target host arch ($target_arch) is not among the built platform(s) ($platforms) — the image may fail to start on the target host (exec format error)."
  return 0
}

# deploy_stack <stack> <env_file> [services_profile]
#
# Brings up the stack at stacks/<stack>/docker-compose.yml using the given
# env file and optional Docker Compose profile for optional service groups.
#
# Arguments:
#   stack           — stack name (must match a directory under stacks/)
#   env_file        — path to .env file (must exist)
#   services_profile — optional Docker Compose profile (messaging|ui|full)
set -euo pipefail

deploy_stack() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  local compose_file="$stack_dir/docker-compose.yml"

  deploy_prepare "$stack" "$stack_dir" "$compose_file" "$env_file"

  # Build compose command via canonical helper
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services_profile")
  local env_name
  env_name=$(extract_env_name "$env_file")

  print_banner "Multi-Service Deploy"
  log "Stack: $stack | Env: $env_name | Services: ${services_profile:-core}"

  # Pre-flight
  log "[1/5] Pre-flight checks..."
  require_cmd docker "Install with: curl -fsSL https://get.docker.com | bash"
  docker compose version &>/dev/null || fail "Docker Compose plugin not found"
  ok "Pre-flight checks passed"

  # Pre-deploy validation (unless skipped)
  if [ "${SKIP_VALIDATION:-false}" != "true" ] && [ "${PRE_DEPLOY_VALIDATE:-true}" = "true" ]; then
    log "[2/7] Pre-deploy validation..."
  fi
  deploy_run_pre_deploy_validation "$stack" "$stack_dir" "$env_file" "$env_name" "$compose_cmd"

  # Dry-run: show execution plan and exit early
  if [ "$DRY_RUN" = "true" ]; then
    load_services_conf "$stack_dir"
    local dry_build_mode="${BUILD_MODE:-registry}"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for deploy (BUILD_MODE=$dry_build_mode):${NC}"
    if [ "$dry_build_mode" = "registry" ]; then
      local registry_type="${REGISTRY_TYPE:-none}"
      if [ "$registry_type" != "none" ]; then
        local registry_host="${REGISTRY_HOST:-}"
        if [ -n "$registry_host" ]; then
          run_cmd "Authenticate with registry ($registry_type: $registry_host)" echo "registry auth"
        else
          run_cmd "Authenticate with registry ($registry_type)" echo "registry auth"
        fi
      fi
      run_cmd "Pull latest images" $compose_cmd pull
    elif [ "$dry_build_mode" = "local" ]; then
      if [ -n "${PLATFORMS:-}" ]; then
        run_cmd "Build images ($PLATFORMS) via buildx" docker buildx bake -f "$compose_file" --set "*.platform=$PLATFORMS"
        _deploy_warn_arch_mismatch "$stack" "$PLATFORMS"
      else
        run_cmd "Build images on target" $compose_cmd build
      fi
    else
      run_cmd "Skip image pull/build (BUILD_MODE=$dry_build_mode)" echo "skipped"
    fi
    run_cmd "Create data directories" mkdir -p "$stack_dir/data/..."

    # Read-only, so it runs for real even in dry-run — surfaces strut#418's
    # cross-stack COMPOSE_PROJECT_NAME collision before an operator ever
    # risks a live deploy.
    local dry_project_name
    dry_project_name=$(echo "$compose_cmd" | grep -oE '\-\-project\-name [^ ]+' | awk '{print $2}') || true
    _deploy_guard_project_collision "$compose_file" "${dry_project_name:-$stack}" \
      || { fail "[DRY-RUN] Would abort here — see above."; return 1; }

    run_cmd "Stop existing containers" $compose_cmd down --remove-orphans
    run_cmd "Start services" $compose_cmd up -d --remove-orphans
    local proxy="${REVERSE_PROXY:-nginx}"
    local reload_cmd
    if reload_cmd=$(build_proxy_reload_cmd "$compose_cmd" "$proxy"); then
      run_cmd "Reload reverse proxy" $reload_cmd
    fi
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Load services.conf early so BUILD_MODE and other config is available
  # for the registry/build decision below.
  load_services_conf "$stack_dir"
  local build_mode="${BUILD_MODE:-registry}"

  # Registry login (dispatches based on REGISTRY_TYPE from config)
  # Skipped when BUILD_MODE=local or BUILD_MODE=none (no registry needed)
  # A multi-arch PLATFORMS build (even under BUILD_MODE=local) can't --load
  # into the local image store, so it must --push — which needs registry
  # auth up front, same as BUILD_MODE=registry.
  local _platforms_count=0
  if [ -n "${PLATFORMS:-}" ]; then
    local -a _platforms_arr
    IFS=',' read -ra _platforms_arr <<< "$PLATFORMS"
    _platforms_count="${#_platforms_arr[@]}"
  fi

  if [ "$build_mode" = "registry" ]; then
    log "[2/5] Authenticating with registry..."
    registry_login
  elif [ "$build_mode" = "local" ] && [ "$_platforms_count" -gt 1 ]; then
    log "[2/5] Authenticating with registry (multi-arch build must push)..."
    registry_login
  elif [ "$build_mode" = "local" ]; then
    log "[2/5] Skipping registry auth (BUILD_MODE=local)"
  else
    log "[2/5] Skipping registry auth (BUILD_MODE=$build_mode)"
  fi

  # Save rollback snapshot before pulling/building new images
  local strut_home="${STRUT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  source "$strut_home/lib/rollback.sh"
  rollback_save_snapshot "$stack" "$compose_cmd" "$env_name"

  # Pull or build images based on BUILD_MODE
  if [ "$build_mode" = "local" ]; then
    log "[3/5] Building images on target..."
    _deploy_build_images "$stack" "$compose_cmd" "$stack_dir" || fail "Image build failed"
    ok "Images built successfully"
  elif [ "$build_mode" = "none" ]; then
    log "[3/5] Skipping image pull/build (BUILD_MODE=none)"
  else
    log "[3/5] Pulling latest images..."
    docker_pull_stack "$compose_cmd"
    # Abort BEFORE stopping the running stack if a required image is missing
    # (e.g. expired registry token). Prevents tearing the stack down only to
    # fail on restart, or silently deploying stale cached images.
    docker_require_images "$compose_cmd" \
      || fail "Aborting deploy: required images could not be pulled — the running stack was left untouched. Check registry auth (GH_PAT/DOCKER_PASS) and network connectivity."
  fi

  # Data directories — explicit STACK_DATA_DIRS wins; otherwise derive from
  # the same DB_* flags in services.conf that health.sh reads, falling back
  # to a single generic "data" dir when none are set. See
  # _deploy_resolve_data_dirs for the full precedence rules.
  log "[4/5] Creating data directories..."
  local data_dirs
  data_dirs=$(_deploy_resolve_data_dirs)
  for dir in $data_dirs; do
    mkdir -p "$stack_dir/$dir"
  done
  ok "Data directories ready"

  local project_name
  project_name=$(echo "$compose_cmd" | grep -oE '\-\-project\-name [^ ]+' | awk '{print $2}') || true

  # Refuse to proceed if the resolved project name is shared with a
  # different, unrelated stack (strut#418) — down/up --remove-orphans below
  # would delete that stack's live containers.
  _deploy_guard_project_collision "$compose_file" "${project_name:-$stack}" \
    || { fail "Aborting deploy: the running stack was left untouched (see above)."; return 1; }

  # Stop any existing containers to free up ports
  log "[5/6] Stopping existing containers..."
  $compose_cmd down --remove-orphans 2>/dev/null || true  # may not be running yet

  # Force-remove any orphaned containers with explicit container_name that
  # docker compose down may have missed (e.g. from a previously failed deploy),
  # scoped to containers actually owned by this project — see
  # _deploy_reclaim_named_containers.
  _deploy_reclaim_named_containers "$compose_file" "${project_name:-$stack}"

  ok "Existing containers stopped"

  # Bring up stack. This step runs after the previous containers were
  # already stopped (:327), so a failure here leaves the stack DOWN — it
  # must never fall through to the success banner/notify_event below.
  # Guarded explicitly (not relying on ambient `set -e`) because callers
  # like `deploy_stack ... || _deploy_rc=$?` (cmd_deploy.sh) put this whole
  # call on the left side of `||`, which suppresses errexit for the entire
  # call tree per POSIX/bash semantics.
  log "[6/6] Starting services..."
  if ! $compose_cmd up -d --remove-orphans; then
    error "compose up failed — the stack was already stopped and is now DOWN"
    notify_event deploy.failed stack="$stack" env="$env_name" reason="compose_up_failed"
    return 1
  fi

  # Health-gate the deploy instead of a fixed 60s sleep (strut#407): poll
  # this project's own containers (running + Docker health + RestartCount,
  # via _bg_wait_healthy) until healthy, and fail the deploy on timeout or
  # crash-loop instead of falling through to the success banner. Stacks
  # without healthchecks pass as soon as their containers hold "running"
  # across consecutive polls, so most deploys get FASTER, not slower.
  # Skip with --skip-health-gate or DEPLOY_SKIP_HEALTH_GATE=1 (for one-shot
  # containers / migration stacks that exit immediately after up).
  if [ "${DEPLOY_SKIP_HEALTH_GATE:-false}" = "true" ] || [ "${DEPLOY_SKIP_HEALTH_GATE:-0}" = "1" ]; then
    log "Health gate skipped (DEPLOY_SKIP_HEALTH_GATE)"
  else
    declare -F _bg_wait_healthy >/dev/null || source "$LIB/deploy_blue_green.sh"
    local _deploy_health_timeout="${DEPLOY_HEALTH_TIMEOUT:-60}"
    local _deploy_health_rc=0
    _bg_wait_healthy "$stack_dir" "$compose_cmd" "$compose_file" \
      "$_deploy_health_timeout" "stack" || _deploy_health_rc=$?
    if [ "$_deploy_health_rc" -ne 0 ]; then
      error "services did not become healthy within ${_deploy_health_timeout}s — NOT printing the success banner (raise with DEPLOY_HEALTH_TIMEOUT=<seconds>)"
      # Fire on_health_fail hook (warn-only — never mask the gate's failure)
      HEALTH_STATUS="$_deploy_health_rc" fire_hook_or_warn on_health_fail "$stack_dir"
      notify_event deploy.failed stack="$stack" env="$env_name" reason="health_gate_failed"
      return 1
    fi
  fi

  # Reload reverse proxy to pick up any new container IPs
  local proxy="${REVERSE_PROXY:-nginx}"
  if $compose_cmd ps "$proxy" &>/dev/null && $compose_cmd ps "$proxy" | grep -q "Up"; then
    log "Reloading $proxy to refresh backend IPs..."
    local reload_cmd
    if reload_cmd=$(build_proxy_reload_cmd "$compose_cmd" "$proxy"); then
      $reload_cmd 2>/dev/null && ok "$proxy reloaded" || warn "$proxy reload failed (may not be critical)"
    fi
  else
    warn "$proxy container not running — skipping reload"
  fi

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✓  Deploy complete (stack: $stack, env: $env_name, services: ${services_profile:-core})${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""

  # Print each service's endpoint from services.conf (*_PORT / *_HEALTH_PATH),
  # mirroring health_check_application's discovery logic.
  local _svc_conf="$stack_dir/services.conf"
  if [ -f "$_svc_conf" ]; then
    local _svc_conf_content
    _svc_conf_content=$(cat "$_svc_conf")
    while IFS='=' read -r _svc_key _svc_value; do
      [[ -z "$_svc_key" || "$_svc_key" =~ ^[[:space:]]*# ]] && continue
      _svc_key=$(echo "$_svc_key" | xargs)
      _svc_value=$(echo "$_svc_value" | xargs)
      [[ "$_svc_key" == DB_* ]] && continue
      [[ "$_svc_key" != *_PORT ]] && continue
      local _svc_prefix="${_svc_key%_PORT}"
      local _svc_name
      _svc_name=$(echo "$_svc_prefix" | tr '[:upper:]_' '[:lower:]-')
      local _svc_health_path
      _svc_health_path=$(echo "$_svc_conf_content" | grep -E "^${_svc_prefix}_HEALTH_PATH=" 2>/dev/null | head -1 | cut -d'=' -f2- | xargs) || true
      echo "  ${_svc_name}: http://localhost:${_svc_value}${_svc_health_path}"
    done <<< "$_svc_conf_content"
  fi
  echo "  Logs:   $compose_cmd logs -f"
  echo "  Status: $compose_cmd ps"
  echo ""

  # Fire post_deploy lifecycle hook (non-fatal on failure)
  # First, run one-time first-run hook if needed (after services are up)
  fire_first_run_hook "$stack_dir" || warn "First-run hook failed — deploy continues"
  # Apply DB schema (opt-in, idempotent) — mirrors the blue-green path
  maybe_apply_db_schema "$stack" "$compose_cmd" "$stack_dir"
  DEPLOY_STATUS="ok" fire_hook_or_warn post_deploy "$stack_dir"

  # Install declarative timers (timers.conf → systemd .service/.timer pairs).
  # No-op when the stack has no timers.conf; never abort a successful deploy.
  # Sourced lazily (not at file scope) so merely sourcing deploy.sh — e.g. for
  # render_safe_clean_snippet in the migrate wizard — doesn't pull in timers.sh
  # (and transitively utils.sh) as a side effect.
  if ! declare -f timers_install >/dev/null 2>&1; then
    # shellcheck source=lib/timers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timers.sh"
  fi
  timers_install "$stack" "$stack_dir" || warn "Timer install failed — deploy continues"

  # Notification providers (Slack/Discord/webhook) subscribed to deploy.success
  notify_event deploy.success \
    stack="$stack" \
    env="$env_name" \
    services="${services_profile:-core}"
}

# vps_update_repo <stack> <env_file>
#
# SSHes into the VPS and updates the strut checkout in VPS_DEPLOY_DIR via
# git fetch + reset --hard, so local drift (dirty files, diverged commits)
# never blocks a deploy. Verifies the strut binary is present and executable
# after the update.
#
# Requires in env file: VPS_HOST, VPS_USER (default: ubuntu)
# Optional:             VPS_SSH_KEY, VPS_DEPLOY_DIR (default: /home/$VPS_USER/strut)
vps_update_repo() {
  local stack="$1"
  local env_file="$2"

  validate_env_file "$env_file" VPS_HOST GH_PAT

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)
  local gh_pat="${GH_PAT:-}"
  local branch="${DEFAULT_BRANCH:-main}"
  local env_name; env_name=$(extract_env_name "$env_file")

  log "Updating strut on $vps_user@$vps_host → $deploy_dir"
  warn "Any local changes on the VPS will be discarded (hard reset to origin/$branch)"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Verify deploy dir exists before syncing
  # Intentional: variables expand locally before SSH
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$vps_user@$vps_host" "[ -d '$deploy_dir' ]" 2>/dev/null; then
    fail "$deploy_dir not found on VPS. strut is not initialized on this host. Run: strut $stack remote:init --env $env_name"
  fi

  # Sync the checkout via fleet_sync (fetch + reset --hard + guarded clean).
  # GH_PAT is forwarded so fetch works regardless of whether the remote is SSH
  # or HTTPS. We use reset --hard rather than pull so local drift on the VPS
  # (modified tracked files, conflicting untracked files) never blocks the sync.
  local fleet_sync_opts=()
  [ "${FORCE_CLEAN:-false}" = "true" ] && fleet_sync_opts+=(--force-clean)

  fleet_sync "$vps_user" "$vps_host" "$vps_port" "$vps_ssh_key" \
    "$deploy_dir" "$branch" "$gh_pat" "${fleet_sync_opts[@]+"${fleet_sync_opts[@]}"}" \
    || fail "Update failed — check VPS_HOST, VPS_SSH_KEY, and VPS_DEPLOY_DIR"

  # Verify strut binary is present and executable after sync
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    if [ ! -f '$deploy_dir/strut' ]; then
      echo 'ERROR: strut binary not found in $deploy_dir after update' >&2
      echo '' >&2
      echo 'The deploy directory exists but does not contain the strut executable.' >&2
      echo 'Run: strut $stack remote:init --env $env_name' >&2
      exit 1
    fi
    chmod +x '$deploy_dir/strut'
    echo 'strut binary ready'
  " && ok "strut updated on VPS" || fail "Update failed — strut binary missing after sync"
}

# pull_only_stack <stack> <env_file> [services_profile]
# Only pulls images without starting services.
# When BUILD_MODE=local, builds images instead of pulling.
pull_only_stack() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"

  if [ ! -f "$env_file" ]; then
    local _hint _msg
    _hint=$(_env_not_found_hint "$env_file")
    _msg="Env file not found: $env_file"
    [ -n "$_hint" ] && _msg="$_msg
$_hint"
    fail "$_msg"
  fi

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"

  load_common_env
  safe_load_env "$env_file"
  env_apply_layers "$stack" "$stack_dir"

  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services_profile")

  load_services_conf "$stack_dir"
  local build_mode="${BUILD_MODE:-registry}"

  if [ "$build_mode" = "local" ]; then
    log "Building images on target (BUILD_MODE=local)..."
    # A multi-arch PLATFORMS build can't --load, so it must --push — needs
    # registry auth up front (see the matching guard in deploy_stack).
    local _platforms_count=0
    if [ -n "${PLATFORMS:-}" ]; then
      local -a _platforms_arr
      IFS=',' read -ra _platforms_arr <<< "$PLATFORMS"
      _platforms_count="${#_platforms_arr[@]}"
    fi
    [ "$_platforms_count" -gt 1 ] && registry_login
    _deploy_build_images "$stack" "$compose_cmd" "$stack_dir" || fail "Image build failed"
    ok "Build complete."
  elif [ "$build_mode" = "none" ]; then
    log "Skipping pull/build (BUILD_MODE=none)"
    ok "Nothing to pull or build."
  else
    registry_login
    docker_pull_stack "$compose_cmd"
    ok "Pull complete."
  fi
}

# vps_release <stack> <env_file> [services_profile]
#
# Complete release workflow for VPS deployment:
# 1. Update strut repo on VPS
# 2. Run database migrations (Postgres + Neo4j)
# 3. Pull latest container images
# 4. Restart services
# 5. Verify deployment
#
# This is the recommended way to deploy updates to production.
vps_release() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"
  local auto_rollback="${4:-true}"
  local backup_first="${5:-false}"

  validate_env_file "$env_file" VPS_HOST

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"
  local vps_port="${VPS_PORT:-22}"
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)
  local env_name
  env_name=$(extract_env_name "$env_file")

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  local _release_start_epoch
  _release_start_epoch=$(date +%s 2>/dev/null || echo 0)

  # Resolve history_actor() from the CONTROLLER's own file location (not
  # $LIB/$STRUT_HOME, which tests may point elsewhere) — actor identity must
  # come from here, since CI vars like GITHUB_ACTOR live on the controller
  # running this release, not on the target VPS reached over SSH below.
  if ! declare -F history_actor >/dev/null; then
    local _release_lib_dir
    _release_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_release_lib_dir/history.sh"
  fi
  local _release_actor
  _release_actor=$(history_actor)
  # _release_actor is interpolated (not deferred like git_sha/release_id)
  # into the remote command string below, so it must be shell-quoted here
  # on the controller. history_actor() can resolve to CI_COMMIT_AUTHOR —
  # an attacker-controlled git commit author — so an unescaped value would
  # let shell metacharacters in a commit author execute on the deploy host.
  local _release_actor_q
  _release_actor_q="'$(printf '%s' "$_release_actor" | sed "s/'/'\\\\''/g")'"
  local _release_mode="${DEPLOY_MODE:-standard}"

  print_banner "VPS Release Deploy"
  log "Target: $vps_user@$vps_host"
  log "Stack: $stack | Env: $env_name | Services: ${services_profile:-core}"
  echo ""

  # Local (controller-side) stack dir — used by pre_deploy_local /
  # post_deploy_local, which run here on the controller rather than being
  # SSH'd to the target host like every other release step.
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local local_stack_dir="${CMD_STACK_DIR:-$cli_root/stacks/$stack}"

  # Dry-run: show execution plan and exit early
  if [ "$DRY_RUN" = "true" ]; then
    local branch="${DEFAULT_BRANCH:-main}"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for release:${NC}"
    RELEASE_ENV_NAME="$env_name" fire_hook pre_deploy_local "$local_stack_dir"
    if [ "$backup_first" = "true" ]; then
      run_cmd "Back up databases before release (--backup-first)" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack backup all --env $env_name"
    fi
    run_cmd "Update strut repo on VPS" ssh "$vps_user@$vps_host" "cd $deploy_dir && git fetch && git reset --hard origin/$branch"
    # git clean -nd is itself non-destructive, so show a real preview of what
    # the guarded clean step would remove, not just descriptive text — the
    # one destructive step in an otherwise reversible release.
    local _clean_preview
    # shellcheck disable=SC2029
    _clean_preview=$(ssh $ssh_opts "$vps_user@$vps_host" "cd '$deploy_dir' 2>/dev/null && git clean -nd 2>/dev/null") || _clean_preview=""
    if [ -n "$_clean_preview" ]; then
      warn "  git clean -fd would remove the following untracked paths (skipped unless --force-clean):"
      echo "$_clean_preview" | sed 's/^/    /'
    else
      log "  git clean -fd would remove nothing (no untracked paths, or host unreachable)"
    fi
    run_cmd "Run Postgres migrations" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack migrate postgres --env $env_name"
    run_cmd "Run Neo4j migrations" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack migrate neo4j --env $env_name"
    run_cmd "Pull latest images" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack deploy --env $env_name --pull-only"
    run_cmd "Restart services" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack deploy --env $env_name"
    run_cmd "Verify deployment" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack health --env $env_name"
    if [ "$auto_rollback" = "true" ]; then
      run_cmd "Roll back on health failure (auto)" ssh "$vps_user@$vps_host" "cd $deploy_dir && ./strut $stack rollback --env $env_name"
    fi
    RELEASE_ENV_NAME="$env_name" fire_hook post_deploy_local "$local_stack_dir"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # pre_deploy_local: controller-side hook, fired before ANYTHING else in
  # the release touches the target host (unlike pre_deploy/post_deploy,
  # which run on the target host inside the remote `deploy` invocation
  # below). Reads the local stack dir, not the remote deploy_dir. Can
  # abort the release.
  RELEASE_ENV_NAME="$env_name" fire_hook pre_deploy_local "$local_stack_dir" \
    || fail "pre_deploy_local hook failed — aborting release"

  # Pre-deploy backup (opt-in — Neo4j backups require ~10-30s of downtime,
  # so this is never silently default-on). Runs before anything else changes
  # so the snapshot reflects truly pre-release state, not post-migration.
  if [ "$backup_first" = "true" ]; then
    log "Backing up databases before release (--backup-first)..."
    # shellcheck disable=SC2029
    ssh $ssh_opts "$vps_user@$vps_host" "
      cd '$deploy_dir'
      ./strut $stack backup all --env $env_name
    " || fail "Pre-deploy backup failed — aborting release. Check backup config/logs, or omit --backup-first to skip."
    ok "Pre-deploy backup complete"
  fi

  # Step 1: Update repo
  log "[1/6] Updating strut repository on VPS..."
  vps_update_repo "$stack" "$env_file"

  # Step 2: Run Postgres migrations
  log "[2/6] Running Postgres migrations..."
  local migration_mode="${MIGRATION_FAILURE_MODE:-warn}"
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack migrate postgres --env $env_name
  "; then
    if [ "$migration_mode" = "halt" ]; then
      fail "Postgres migration failed — halting release (MIGRATION_FAILURE_MODE=halt)"
    else
      warn "Postgres migration failed or no migrations to apply"
    fi
  fi

  # Step 3: Run Neo4j migrations
  log "[3/6] Running Neo4j migrations..."
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack migrate neo4j --env $env_name
  "; then
    if [ "$migration_mode" = "halt" ]; then
      fail "Neo4j migration failed — halting release (MIGRATION_FAILURE_MODE=halt)"
    else
      warn "Neo4j migration failed or no migrations to apply"
    fi
  fi

  # Step 4: Pull latest images
  log "[4/6] Pulling latest container images..."
  local profile_flag=""
  [ -n "$services_profile" ] && profile_flag="--services $services_profile"
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack deploy --env $env_name $profile_flag --pull-only
  " || fail "Failed to pull images"

  # Step 5: Restart services
  log "[5/6] Restarting services..."
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack deploy --env $env_name $profile_flag
  " || fail "Failed to restart services"

  # Step 6: Verify deployment
  log "[6/6] Verifying deployment..."
  sleep 10  # Give services time to start
  local health_ok=true
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    ./strut $stack health --env $env_name $profile_flag
  " || health_ok=false
  if [ "$health_ok" = "false" ]; then
    if [ "$auto_rollback" = "true" ]; then
      warn "Health check failed — rolling back to the previous release..."
      # shellcheck disable=SC2029
      if ssh $ssh_opts "$vps_user@$vps_host" "
        cd '$deploy_dir'
        ./strut $stack rollback --env $env_name
      "; then
        ok "Rolled back to the previous release"
      else
        warn "Automatic rollback also failed — manual intervention required."
      fi
    else
      warn "Health check failed (auto-rollback disabled with --no-rollback)"
    fi
  fi

  # Record release history on the remote host — same disk-durability
  # reasoning as every other release step: it lives with the deploy dir,
  # so `strut <stack> history` (remote-dispatched) finds it after reboots.
  # Recorded before the fail() below so a failed release still gets an
  # outcome=failed entry instead of history recording being skipped by exit.
  local release_outcome="success"
  [ "$health_ok" = "false" ] && release_outcome="failed"
  local _release_end_epoch
  _release_end_epoch=$(date +%s 2>/dev/null || echo "$_release_start_epoch")
  local release_duration=$(( _release_end_epoch - _release_start_epoch ))
  # git_sha and release_id are computed ON THE REMOTE HOST: that's the SHA
  # actually deployed (the controller's checkout may be dirty/ahead), and
  # the snapshot that this release's own `deploy` step just saved lives
  # there too. actor/mode are interpolated from the controller (see above)
  # since CI identity and the resolved DEPLOY_MODE config live here.
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    cd '$deploy_dir'
    source lib/utils.sh 2>/dev/null
    source lib/history.sh 2>/dev/null
    _release_sha=\$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    _release_snapshot=\$(ls -t 'stacks/$stack/.rollback'/*.json 2>/dev/null | head -1)
    _release_id=''
    [ -n \"\$_release_snapshot\" ] && _release_id=\$(basename \"\$_release_snapshot\" .json)
    history_record 'stacks/$stack' release '$release_outcome' env=$env_name duration_s:=$release_duration mode=$_release_mode git_sha=\$_release_sha actor=$_release_actor_q release_id=\$_release_id
  " >/dev/null 2>&1 || true

  if [ "$health_ok" = "false" ]; then
    fail "Release failed health checks after deploy — check logs with: strut $stack logs --env $env_name"
  fi

  # Auto-SSL: provision certs for detected domains (if configured)
  local strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
  if [ -f "$strut_home/lib/ssl/auto.sh" ]; then
    source "$strut_home/lib/ssl/auto.sh"
    ssl_auto_provision "$stack" "$env_file" "$ssh_opts" "$vps_user" "$vps_host" "$deploy_dir" || true
  fi

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✓  Release complete!${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "  Next steps:"
  echo "    View logs:   strut $stack logs <service> --env $env_name --follow"
  echo "    Check status: strut $stack status --env $env_name"
  echo "    SSH to VPS:   strut $stack shell --env $env_name"
  echo ""

  # post_deploy_local: controller-side hook, warn-only. Fires after a
  # successful release (the health-failure path above already returned via
  # fail(), mirroring post_deploy's success-only semantics on the target
  # host).
  RELEASE_ENV_NAME="$env_name" fire_hook_or_warn post_deploy_local "$local_stack_dir"
}
