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

# _docker_unused_images
#   Emits `<repo:tag>\n` for every image that is not currently in use by a
#   running container. Filters out `<none>:<none>` dangling images (those
#   have a separate prune step). Used by `docker_prune` when we want to
#   manually rmi a filtered subset (e.g. to protect rollback-referenced
#   images).
_docker_unused_images() {
  local running_images
  running_images=$(docker ps --format '{{.Image}}' 2>/dev/null | sort -u)
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -v '<none>' \
    | grep -v '^:$' \
    | awk -v running="$running_images" '
        BEGIN { n = split(running, arr, "\n"); for (i=1; i<=n; i++) used[arr[i]] = 1 }
        !($0 in used) { print }
      '
}

# docker_prune_protected <protected_images...>
#
# Prunes unused images except those in the protected list. Called by
# `docker_prune` when `--all --protect <img> [<img>...]` is supplied and
# gives us fine-grained control that `docker image prune -a` can't.
# Dry-run mode is controlled by $DRY_RUN.
docker_prune_protected() {
  local -a protected=("$@")
  declare -A protect
  local img
  for img in "${protected[@]+"${protected[@]}"}"; do
    protect["$img"]=1
  done

  local unused
  unused=$(_docker_unused_images)

  local to_prune=() to_keep=()
  while IFS= read -r img; do
    [ -z "$img" ] && continue
    if [ "${protect[$img]:-0}" = "1" ]; then
      to_keep+=("$img")
    else
      to_prune+=("$img")
    fi
  done <<< "$unused"

  if [ "${#to_keep[@]}" -gt 0 ]; then
    log "Protecting ${#to_keep[@]} image(s) referenced by rollback snapshots:"
    for img in "${to_keep[@]}"; do
      echo "  • $img"
    done
  fi

  if [ "${#to_prune[@]}" -eq 0 ]; then
    ok "No unused images to prune"
    return 0
  fi

  log "Pruning ${#to_prune[@]} unused image(s)..."
  for img in "${to_prune[@]}"; do
    if [ "${DRY_RUN:-false}" = "true" ]; then
      echo "  [dry-run] docker rmi $img"
    else
      docker rmi "$img" 2>/dev/null || warn "Failed to remove $img (may be in use)"
    fi
  done
}

# docker_prune [--volumes] [--all] [--stack <name>]
#
# Interactively prunes unused Docker resources: dangling images, build cache,
# and optionally all unused images and anonymous volumes. Each step prompts
# for confirmation.
#
# Args:
#   --volumes       — Also remove anonymous volumes
#   --all           — Remove all unused images (not just dangling)
#   --stack <name>  — Scope the prune to a stack's context; rollback snapshots
#                     for <name> will protect their referenced images from
#                     pruning (respect ROLLBACK_RETENTION_DAYS). Off by default;
#                     PRUNE_PROTECT_ROLLBACK_IMAGES=false opts out even when
#                     --stack is provided.
#
# Side effects: Removes Docker images, build cache, and optionally volumes
docker_prune() {
  local remove_volumes=false
  local remove_all=false
  local scope_stack=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --volumes) remove_volumes=true; shift ;;
      --all)     remove_all=true;     shift ;;
      --stack)   scope_stack="${2:-}"; shift 2 ;;
      --stack=*) scope_stack="${1#*=}"; shift ;;
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

  # All unused images — protected by rollback snapshots when applicable.
  if $remove_all; then
    local -a protected=()
    if [ -n "$scope_stack" ] && [ "${PRUNE_PROTECT_ROLLBACK_IMAGES:-true}" = "true" ]; then
      if declare -F rollback_protected_images >/dev/null; then
        while IFS= read -r p; do
          [ -n "$p" ] && protected+=("$p")
        done < <(rollback_protected_images "$scope_stack")
      fi
    fi

    if [ "${#protected[@]}" -gt 0 ]; then
      confirm "Remove unused images (protecting ${#protected[@]} referenced by rollback)?" \
        && docker_prune_protected "${protected[@]}"
    else
      confirm "Remove ALL unused images (not currently used by any container)?" \
        && docker image prune -a -f
    fi
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
