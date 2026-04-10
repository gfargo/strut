#!/usr/bin/env bash
# ==================================================
# lib/registry.sh — Pluggable container registry authentication
# ==================================================
# Requires: lib/utils.sh sourced first
# Requires: lib/config.sh sourced first (REGISTRY_TYPE, REGISTRY_HOST)
#
# Provides:
#   registry_login — dispatch to the correct auth method based on REGISTRY_TYPE

set -euo pipefail

# registry_login
#
# Dispatches registry authentication based on REGISTRY_TYPE from config.
#   ghcr      → authenticate with GH_PAT against ghcr.io
#   dockerhub → authenticate with DOCKER_USER/DOCKER_PASS against Docker Hub
#   ecr       → authenticate with aws ecr get-login-password against REGISTRY_HOST
#   none      → no-op (log skip)
#   *         → fail with supported types list
#
# On auth failure: warn + continue (local build fallback).
#
# Optional env: DOCKER_SUDO_PREFIX — set to "sudo " for hosts where the deploy
#   user is not in the docker group. Callers can set this from _docker_sudo()
#   or vps_sudo_prefix() before calling registry_login.
registry_login() {
  local registry_type="${REGISTRY_TYPE:-none}"

  case "$registry_type" in
    ghcr)
      _registry_login_ghcr
      ;;
    dockerhub)
      _registry_login_dockerhub
      ;;
    ecr)
      _registry_login_ecr
      ;;
    none)
      log "Registry type is 'none' — skipping authentication"
      ;;
    *)
      fail "Unsupported registry type: '$registry_type'. Supported types: ghcr, dockerhub, ecr, none"
      ;;
  esac
}

# ── Internal auth handlers ────────────────────────────────────────────────────

_registry_login_ghcr() {
  [ -n "${GH_PAT:-}" ] || fail "GH_PAT not set — needed for GHCR authentication"
  log "Authenticating with GHCR..."
  local sudo_prefix="${DOCKER_SUDO_PREFIX:-}"
  echo "$GH_PAT" | ${sudo_prefix}docker login ghcr.io -u github-actions --password-stdin \
    && ok "GHCR login successful" \
    || warn "GHCR login failed — will try to build locally"
}

_registry_login_dockerhub() {
  [ -n "${DOCKER_USER:-}" ] || fail "DOCKER_USER not set — needed for Docker Hub authentication"
  [ -n "${DOCKER_PASS:-}" ] || fail "DOCKER_PASS not set — needed for Docker Hub authentication"
  log "Authenticating with Docker Hub..."
  local sudo_prefix="${DOCKER_SUDO_PREFIX:-}"
  echo "$DOCKER_PASS" | ${sudo_prefix}docker login -u "$DOCKER_USER" --password-stdin \
    && ok "Docker Hub login successful" \
    || warn "Docker Hub login failed — will try to build locally"
}

_registry_login_ecr() {
  [ -n "${REGISTRY_HOST:-}" ] || fail "REGISTRY_HOST not set — needed for ECR authentication"
  log "Authenticating with ECR ($REGISTRY_HOST)..."
  local sudo_prefix="${DOCKER_SUDO_PREFIX:-}"
  aws ecr get-login-password | ${sudo_prefix}docker login --username AWS --password-stdin "$REGISTRY_HOST" \
    && ok "ECR login successful" \
    || warn "ECR login failed — will try to build locally"
}
