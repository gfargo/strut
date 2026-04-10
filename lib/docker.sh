#!/usr/bin/env bash
# ==================================================
# lib/docker.sh — Docker operations
# ==================================================
# Requires: lib/utils.sh sourced first

# ── Docker sudo helper ───────────────────────────────────────────────────────
# Evaluated at call time (after env file is sourced) so VPS_SUDO is respected.
# Returns "sudo " when VPS_SUDO=true, empty string otherwise.
set -euo pipefail

_docker_sudo() { [ "${VPS_SUDO:-false}" = "true" ] && echo "sudo " || echo ""; }

# ── Image management ─────────────────────────────────────────────────────────

# docker_pull_stack <compose_cmd>
#
# Pulls all images defined in a stack's compose file. Non-pullable images
# (e.g. locally-built) are silently skipped via --ignore-pull-failures.
#
# Args:
#   compose_cmd — Full "docker compose -f ... --project-name ..." prefix
#
# Requires env: DOCKER_PULL_PLATFORM (default: linux/amd64)
# Side effects: Pulls Docker images from remote registries
docker_pull_stack() {
  local compose_cmd="$1"
  local platform="${DOCKER_PULL_PLATFORM:-linux/amd64}"
  local sudo_prefix
  sudo_prefix="$(_docker_sudo)"
  log "Pulling latest images..."
  DOCKER_DEFAULT_PLATFORM="$platform" ${sudo_prefix}${compose_cmd} pull --ignore-pull-failures \
    || warn "Some images could not be pulled (may need to build from source)"
}

# docker_prune [--volumes] [--all]
#
# Interactively prunes unused Docker resources: dangling images, build cache,
# and optionally all unused images and anonymous volumes. Each step prompts
# for confirmation.
#
# Args:
#   --volumes — Also remove anonymous volumes
#   --all     — Remove all unused images (not just dangling)
#
# Side effects: Removes Docker images, build cache, and optionally volumes
docker_prune() {
  local remove_volumes=false
  local remove_all=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --volumes) remove_volumes=true; shift ;;
      --all)     remove_all=true;     shift ;;
      *)         shift ;;
    esac
  done

  log "Pruning unused Docker resources..."

  # Dangling images
  local dangling
  dangling=$(docker images -f "dangling=true" -q | wc -l | tr -d ' ')
  if [ "$dangling" -gt 0 ]; then
    confirm "Remove $dangling dangling image(s)?" && docker image prune -f
  else
    ok "No dangling images"
  fi

  # All unused images
  if $remove_all; then
    confirm "Remove ALL unused images (not currently used by any container)?" \
      && docker image prune -a -f
  fi

  # Build cache
  local cache_size
  cache_size=$(docker system df --format '{{.BuildCacheSize}}' 2>/dev/null || echo "unknown")
  confirm "Clear Docker build cache ($cache_size)?" && docker builder prune -f

  # Anonymous volumes
  if $remove_volumes; then
    confirm "Remove anonymous volumes?" && docker volume prune -f
  fi

  ok "Docker prune complete"
}
