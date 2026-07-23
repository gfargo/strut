#!/usr/bin/env bash
# ==================================================
# lib/deploy_blue_green.sh — Blue-green deploy orchestration
# ==================================================
# Requires: lib/utils.sh, lib/docker.sh, lib/health.sh, lib/deploy.sh
#
# Public entry:
#   bg_deploy_stack <stack> <env_file> [services_profile]
#
# The flow stands the new version up under a `-green` (or `-blue`) project
# suffix alongside the current one, health-checks it, swaps the reverse
# proxy upstream, drains the old color, stops it. On health failure the
# new color is torn down and the current color is left untouched.
#
# State: stacks/<stack>/.bluegreen.<env> records the currently-active color
# so the next deploy of that env flips to the opposite slot. A rollback
# reads this file and flips back. State is per-env (not per-stack) because
# project names are per-env (<stack>-<env>-<color>) — a shared file would
# let one env's deploy overwrite another's active color and cause an
# in-place recreation of a live, unrelated project (strut#375). Reads fall
# back to the old per-stack path (stacks/<stack>/.bluegreen) for
# deployments made before this change; the first write under the new
# scheme migrates by deleting the legacy file.
#
# Helpers are underscore-prefixed and intentionally small so tests can
# stub them individually.

set -euo pipefail

# ── State file ────────────────────────────────────────────────────────────────

# _bg_state_file <stack> <env_name>
_bg_state_file() {
  local stack="$1" env_name="${2:-prod}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  echo "$cli_root/stacks/$stack/.bluegreen.$env_name"
}

# _bg_legacy_state_file <stack> — pre-per-env state path. Kept only for a
# backward-compatible read fallback (_bg_read_state) and one-time migration
# (_bg_write_state); nothing writes here anymore.
_bg_legacy_state_file() {
  local stack="$1"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  echo "$cli_root/stacks/$stack/.bluegreen"
}

# _bg_resolve_state_file <stack> <env_name>
#
# Echoes the per-env state file path if it exists, else the legacy
# per-stack path if THAT exists, else nothing. Shared lookup used by every
# state reader so the fallback logic lives in exactly one place.
_bg_resolve_state_file() {
  local stack="$1" env_name="${2:-prod}"
  local f
  f="$(_bg_state_file "$stack" "$env_name")"
  [ -f "$f" ] && { echo "$f"; return 0; }
  f="$(_bg_legacy_state_file "$stack")"
  [ -f "$f" ] && { echo "$f"; return 0; }
  echo ""
}

# _bg_read_state <stack> <env_name> — echoes the current active color or
# empty string. Parses a tiny `active_color=<blue|green>` file (not JSON,
# to avoid a jq dependency on the fast path). Falls back to the legacy
# per-stack file when no per-env file exists yet.
_bg_read_state() {
  local stack="$1" env_name="${2:-prod}"
  local f
  f="$(_bg_resolve_state_file "$stack" "$env_name")"
  [ -n "$f" ] || { echo ""; return 0; }
  awk -F= '$1 == "active_color" { print $2; exit }' "$f" | tr -d '[:space:]"'
}

# _bg_active_project <stack> <env_name>
#
# Echoes the compose project name of the currently-active color, or empty
# string if this stack/env isn't in blue-green mode. stop/status/health use
# this to target the color actually serving traffic — the plain
# <stack>-<env> project blue-green deploys never touch (strut#384).
_bg_active_project() {
  local stack="$1" env_name="${2:-prod}"
  local f
  f="$(_bg_resolve_state_file "$stack" "$env_name")"
  [ -n "$f" ] || { echo ""; return 0; }
  awk -F= '$1 == "active_project" { print $2; exit }' "$f" | tr -d '[:space:]"'
}

# _bg_write_state <stack> <env_name> <color> [project]
_bg_write_state() {
  local stack="$1" env_name="${2:-prod}" color="$3" project="${4:-}"
  local f
  f="$(_bg_state_file "$stack" "$env_name")"
  mkdir -p "$(dirname "$f")"
  {
    echo "active_color=$color"
    [ -n "$project" ] && echo "active_project=$project"
    echo "updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$f"
  # One-time migration: now that this env has its own state file, drop the
  # legacy shared one so a different env can't misread it later.
  rm -f "$(_bg_legacy_state_file "$stack")"
}

# _bg_clear_state <stack> <env_name>
_bg_clear_state() {
  local stack="$1" env_name="${2:-prod}"
  rm -f "$(_bg_state_file "$stack" "$env_name")"
}

# ── Colors ────────────────────────────────────────────────────────────────────

# _bg_flip_color <color> → echoes the opposite color. Unknown → "blue".
_bg_flip_color() {
  case "${1:-}" in
    blue)  echo "green" ;;
    green) echo "blue" ;;
    *)     echo "blue" ;;
  esac
}

# _bg_pick_colors <stack> <env_name>
#
# Echoes two whitespace-separated tokens: "<old_color> <new_color>".
# First deploy (no state): "none blue" — the green slot is empty, new
# color goes to blue.
_bg_pick_colors() {
  local stack="$1" env_name="${2:-prod}"
  local current
  current="$(_bg_read_state "$stack" "$env_name")"
  if [ -z "$current" ]; then
    echo "none blue"
  else
    echo "$current $(_bg_flip_color "$current")"
  fi
}

# ── Project naming ────────────────────────────────────────────────────────────

# _bg_project_name <stack> <env_name> <color>
_bg_project_name() {
  local stack="$1" env_name="$2" color="$3"
  if [ -n "$env_name" ]; then
    echo "${stack}-${env_name}-${color}"
  else
    echo "${stack}-${color}"
  fi
}

# _bg_compose_for_color <stack> <env_file> <color> [services_profile]
#
# Builds a `docker compose …` command string for the given color. Mirrors
# resolve_compose_cmd but forces the `-<color>` project suffix so the two
# colors live in isolated compose projects that can run side by side.
_bg_compose_for_color() {
  local stack="$1" env_file="$2" color="$3" services_profile="${4:-}"
  local env_name
  env_name="$(extract_env_name "$env_file")"
  local project
  project="$(_bg_project_name "$stack" "$env_name" "$color")"

  resolve_compose_cmd "$stack" "$env_file" "$services_profile" "$project"
}

# ── Orchestration steps ───────────────────────────────────────────────────────

# _bg_start_color <compose_cmd>
#
# Pulls images and brings the project up detached. No port rebinding logic
# here — it's the operator's responsibility to ensure their compose file is
# blue-green compatible (no fixed container_name collisions, app services
# don't both try to bind the same host ports). The proxy is intentionally
# left in the compose file; only one color's proxy will win the host port
# at a time, and the swap step (below) reloads the winner.
_bg_start_color() {
  local compose_cmd="$1"
  log "Pulling images for green"
  # shellcheck disable=SC2086
  $compose_cmd pull 2>&1 | grep -v '^$' || true
  # Fail before starting green if a required image didn't pull (expired token,
  # registry down) — otherwise green comes up from stale cache or crash-loops.
  # Skipped for local-build stacks (build_mode=local), which have no registry
  # images to require.
  if [ "${BUILD_MODE:-registry}" != "local" ] && declare -F docker_require_images >/dev/null; then
    docker_require_images "$compose_cmd" \
      || fail "Aborting blue-green deploy: required images could not be pulled — green was not started, blue is untouched."
  fi
  log "Starting green project"
  # shellcheck disable=SC2086
  $compose_cmd up -d --remove-orphans
}

# _bg_any_container_restarted <compose_cmd>
#
# True if any container in the project has a nonzero Docker RestartCount.
# This is the authoritative, timing-independent signal that a container
# crash-looped at some point — unlike polled `State`, it doesn't reset once
# the container cycles back to "running", so it still catches a crash that
# happened to fall between two polls.
_bg_any_container_restarted() {
  local compose_cmd="$1"
  local _sudo
  _sudo="$(vps_sudo_prefix 2>/dev/null || echo "")"

  local cid
  # shellcheck disable=SC2086
  for cid in $($compose_cmd ps -q 2>/dev/null); do
    local restarts
    restarts=$(${_sudo}docker inspect "$cid" --format '{{.RestartCount}}' 2>/dev/null || echo 0)
    [ "${restarts:-0}" -gt 0 ] && return 0
  done
  return 1
}

# _bg_wait_healthy <stack_dir> <compose_cmd> <compose_file> [timeout_seconds] [label]
#
# Polls health_check_project (scoped to the target compose project) until it
# reports healthy or the timeout elapses. Returns 0 healthy, 1 on timeout.
# `label` names what we're waiting on in log output (default "green") — the
# standard deploy path reuses this loop with label "stack" (strut#407).
#
# We snapshot HEALTH_* globals across the probe so the suite's own state
# doesn't leak into the caller.
_bg_wait_healthy() {
  local stack_dir="$1" compose_cmd="$2" compose_file="$3"
  # Standard deploy (deploy.sh) always passes arg 4 explicitly (DEPLOY_HEALTH_TIMEOUT,
  # default 60s). The BLUE_GREEN_HEALTH_TIMEOUT fallback only applies when called from
  # the blue-green path without an explicit timeout argument.
  local timeout="${4:-${BLUE_GREEN_HEALTH_TIMEOUT:-30}}"
  local label="${5:-green}"
  # Overridable only for tests — production callers always get the real 3s
  # poll cadence.
  local interval="${BLUE_GREEN_HEALTH_POLL_INTERVAL:-3}"
  local elapsed=0
  # A single healthy snapshot isn't enough: `up -d` returns as soon as the
  # container reaches "running", which can be a split second before a
  # crash-looping entrypoint actually exits — the very first poll can land
  # in that window and see "running" with no restart yet recorded. Require
  # back-to-back healthy polls so a crash gets at least one interval to
  # reveal itself before we trust it. Widened from 2 to 3: under enough CI
  # runner contention, even RestartCount can still read 0 a full interval
  # after the container first started — the crash hasn't been scheduled and
  # detected by dockerd yet, not just hidden between polls. A wider window
  # gives that detection more real time to happen before we ever accept.
  local required_consecutive=3
  local consecutive_ok=0

  log "Waiting for $label health (timeout: ${timeout}s)"
  while [ "$elapsed" -lt "$timeout" ]; do
    # Use the project-scoped green readiness gate, NOT health_run_all: the
    # latter probes host ports (answered by the still-live blue color, so a
    # dead green would pass) and host-global resources (a load spike during
    # pull would fail a healthy deploy). Subshell keeps its counters local.
    if ( health_check_project "$(basename "$stack_dir")" "$compose_cmd" "$compose_file" >/dev/null 2>&1 ); then
      # Check RestartCount on every passing poll, not just once we've hit
      # the consecutive threshold: a restart spotted on poll 2 should reset
      # progress immediately instead of waiting to be re-derived at the end.
      # RestartCount doesn't have the "mid-'running' between restarts"
      # window a single State snapshot does — it's still nonzero long after
      # the container cycles back to "running".
      if _bg_any_container_restarted "$compose_cmd"; then
        warn "$label container(s) restarted during health checks — not trusting this as healthy"
        consecutive_ok=0
      else
        consecutive_ok=$((consecutive_ok + 1))
        if [ "$consecutive_ok" -ge "$required_consecutive" ]; then
          ok "$label healthy"
          return 0
        fi
      fi
    else
      consecutive_ok=0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo -n "." >&2
  done
  echo "" >&2
  return 1
}

# _bg_swap_proxy <stack> <old_project> <new_project> <env_file>
#
# Atomically flips the reverse proxy upstream from old to new. Pluggable
# via BLUE_GREEN_PROXY_HOOK — when set, the hook file is sourced and must
# define `bluegreen_proxy_swap` with the same signature. Unset hook falls
# back to a best-effort reload of the new project's proxy container; the
# caller is responsible for ensuring that reload actually routes traffic
# (typically by shipping an upstream config that names a Docker DNS alias
# the new color provides).
_bg_swap_proxy() {
  local stack="$1" old_project="$2" new_project="$3" env_file="$4"

  if [ -n "${BLUE_GREEN_PROXY_HOOK:-}" ]; then
    if [ ! -f "$BLUE_GREEN_PROXY_HOOK" ]; then
      fail "BLUE_GREEN_PROXY_HOOK points to missing file: $BLUE_GREEN_PROXY_HOOK"
      return 1
    fi
    # shellcheck disable=SC1090
    source "$BLUE_GREEN_PROXY_HOOK"
    if ! declare -F bluegreen_proxy_swap >/dev/null; then
      fail "Hook $BLUE_GREEN_PROXY_HOOK did not define bluegreen_proxy_swap()"
      return 1
    fi
    log "Swapping proxy via hook: $BLUE_GREEN_PROXY_HOOK"
    bluegreen_proxy_swap "$stack" "$old_project" "$new_project" "$env_file"
    return $?
  fi

  # Built-in fallback: reload the new project's proxy container in place.
  # This is a no-op for routing unless the compose template is built for
  # blue-green (pluggable upstream) — plenty of real stacks are a single
  # app container with no nginx/caddy sidecar at all, so a failed/no-op
  # reload here is expected, not a swap failure. Deliberately non-fatal
  # (warn, not fail/return 1); the strut#375 guard on _bg_swap_proxy's
  # return value is aimed at BLUE_GREEN_PROXY_HOOK, a user-supplied hook
  # that can fail meaningfully (bad nginx config, container not ready) —
  # see the caller in bg_deploy_stack/bg_rollback_stack.
  local proxy="${REVERSE_PROXY:-nginx}"
  local new_cmd
  new_cmd="$(resolve_compose_cmd "$stack" "$env_file" "" "$new_project")"

  warn "No BLUE_GREEN_PROXY_HOOK set — falling back to $proxy reload in $new_project"
  warn "  For true atomic swap, set BLUE_GREEN_PROXY_HOOK in strut.conf"
  local reload_cmd
  if reload_cmd=$(build_proxy_reload_cmd "$new_cmd" "$proxy"); then
    $reload_cmd 2>/dev/null && ok "$proxy reloaded on $new_project" \
      || warn "$proxy reload failed (proxy may not be running yet)"
  else
    warn "Unknown proxy '$proxy' — skipping reload"
  fi
  return 0
}

# _bg_drain <seconds>
#
# Separated out so tests can stub it without waiting. Also honors
# BLUE_GREEN_DRAIN_OVERRIDE (test escape hatch).
_bg_drain() {
  local seconds="${1:-${BLUE_GREEN_DRAIN:-60}}"
  [ -n "${BLUE_GREEN_DRAIN_OVERRIDE:-}" ] && seconds="$BLUE_GREEN_DRAIN_OVERRIDE"
  log "Draining old color for ${seconds}s"
  sleep "$seconds"
}

# _bg_stop_color <compose_cmd>
#
# Stops the old color's project. Uses `stop`, NOT `down`: `down` removes the
# containers, which severs the container↔image binding a later rollback
# depends on — `up -d` would then recreate from whatever the compose file's
# tag currently resolves to (the bad image), not what was actually running.
# `stop` leaves the containers (and volumes) in place so a same-config
# `up -d` just restarts them on their original image.
_bg_stop_color() {
  local compose_cmd="$1"
  # shellcheck disable=SC2086
  $compose_cmd stop 2>/dev/null || true
}

# _bg_teardown_failed_color <compose_cmd>
#
# Invoked when health probes for a freshly-started color never succeed.
# Uses `down --remove-orphans` WITHOUT --volumes: named volumes may be shared
# with the live color (e.g. postgres_data), and destroying them here would
# cause data loss for the running stack. The failed containers are removed
# (freeing ports/names) but volumes are preserved.
_bg_teardown_failed_color() {
  local compose_cmd="$1"
  warn "Tearing down failed green color (volumes preserved)"
  # shellcheck disable=SC2086
  $compose_cmd down --remove-orphans 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────

# bg_deploy_stack <stack> <env_file> [services_profile]
bg_deploy_stack() {
  local stack="$1"
  local env_file="$2"
  local services_profile="${3:-}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  local compose_file="$stack_dir/docker-compose.yml"

  deploy_prepare "$stack" "$stack_dir" "$compose_file" "$env_file"

  local env_name
  env_name="$(extract_env_name "$env_file")"

  # Decide colors
  local pick old_color new_color
  pick="$(_bg_pick_colors "$stack" "$env_name")"
  old_color="${pick%% *}"
  new_color="${pick##* }"

  local old_project new_project
  old_project="$(_bg_project_name "$stack" "$env_name" "$old_color")"
  new_project="$(_bg_project_name "$stack" "$env_name" "$new_color")"
  local new_cmd old_cmd
  new_cmd="$(_bg_compose_for_color "$stack" "$env_file" "$new_color" "$services_profile")"
  old_cmd="$(_bg_compose_for_color "$stack" "$env_file" "$old_color" "$services_profile")"

  print_banner "Blue-Green Deploy"
  log "Stack: $stack | Env: $env_name | Services: ${services_profile:-core}"
  if [ "$old_color" = "none" ]; then
    log "Old: (none — first blue-green deploy)"
  else
    log "Old: $old_project ($old_color)"
  fi
  log "New: $new_project ($new_color)"
  log "Health timeout: ${BLUE_GREEN_HEALTH_TIMEOUT:-30}s | Drain: ${BLUE_GREEN_DRAIN:-60}s"

  # Pre-flight
  log "[1/8] Pre-flight checks..."
  require_cmd docker "Install with: curl -fsSL https://get.docker.com | bash"
  docker compose version &>/dev/null || fail "Docker Compose plugin not found"
  ok "Pre-flight checks passed"

  # Pre-deploy validation (reuse standard path's contract)
  if [ "${SKIP_VALIDATION:-false}" != "true" ] && [ "${PRE_DEPLOY_VALIDATE:-true}" = "true" ]; then
    log "[2/8] Pre-deploy validation..."
  fi
  deploy_run_pre_deploy_validation "$stack" "$stack_dir" "$env_file" "$env_name"

  # Dry-run plan — stop before any side effects.
  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for blue-green deploy:${NC}"
    run_cmd "Authenticate with registry" echo "registry auth"
    run_cmd "Pull images for $new_color" $new_cmd pull
    run_cmd "Start $new_color project"   $new_cmd up -d --remove-orphans
    run_cmd "Wait for $new_color health (timeout: ${BLUE_GREEN_HEALTH_TIMEOUT:-30}s)" echo "probe"
    run_cmd "Swap proxy $old_color → $new_color" echo "swap"
    run_cmd "Mark $new_color as active" echo "write state"
    run_cmd "Drain $old_color (${BLUE_GREEN_DRAIN:-60}s)" echo "drain"
    if [ "$old_color" != "none" ]; then
      run_cmd "Stop $old_color project" $old_cmd stop
    fi
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Registry auth (shared with standard deploy).
  log "[3/8] Authenticating with registry..."
  registry_login

  # Save rollback snapshot of the **current** color before we touch anything.
  # Restore paths: standard rollback restores images; blue-green rollback
  # flips the .bluegreen active_color and brings the old project back up.
  source "${STRUT_HOME:-$cli_root}/lib/rollback.sh"
  if [ "$old_color" != "none" ]; then
    rollback_save_snapshot "$stack" "$old_cmd" "$env_name" || true
  fi

  # Stand up green
  log "[4/8] Starting $new_color project alongside $old_color..."
  _bg_start_color "$new_cmd"

  # Health gate
  log "[5/8] Waiting for $new_color health..."
  if ! _bg_wait_healthy "$stack_dir" "$new_cmd" "$compose_file" "${BLUE_GREEN_HEALTH_TIMEOUT:-30}"; then
    warn "green failed health checks — tearing down and aborting"
    _bg_teardown_failed_color "$new_cmd"
    notify_event deploy.failed stack="$stack" env="$env_name" reason="green_unhealthy"
    fail "Blue-green deploy aborted: $new_color never became healthy (old color untouched)"
    # Belt-and-suspenders: in production `fail` exits, but tests override it
    # to `return 1`, so make the abort explicit either way.
    return 1
  fi

  # Swap proxy. Guarded explicitly — an unchecked failure here used to fall
  # through to draining/stopping the old color anyway, leaving traffic
  # pointed at containers that had just been stopped (strut#375).
  log "[6/8] Swapping reverse proxy: $old_color → $new_color"
  if ! _bg_swap_proxy "$stack" "$old_project" "$new_project" "$env_file"; then
    notify_event deploy.failed stack="$stack" env="$env_name" reason="proxy_swap_failed"
    fail "Blue-green deploy aborted: proxy swap to $new_color failed ($old_color is still active and untouched)"
    return 1
  fi

  # Mark active immediately after the swap succeeds, not after drain/stop
  # below — from this point $new_color is what's actually serving traffic,
  # so a crash or interrupt during drain/stop must not leave the state file
  # still pointing at the old (about-to-be-stopped) color.
  log "Marking $new_color as active"
  _bg_write_state "$stack" "$env_name" "$new_color" "$new_project"

  # Drain
  if [ "$old_color" != "none" ]; then
    log "[7/8] Draining $old_color (${BLUE_GREEN_DRAIN:-60}s)..."
    _bg_drain "${BLUE_GREEN_DRAIN:-60}"

    log "[8/8] Stopping $old_color project..."
    _bg_stop_color "$old_cmd"
  else
    log "[7/8] Skipping drain (no previous color)"
    log "[8/8] Skipping stop (no previous color)"
  fi

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✓  Blue-green deploy complete (stack: $stack, active: $new_color)${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "  Active project:   $new_project"
  [ "$old_color" != "none" ] && echo "  Previous project: $old_project (stopped, volumes retained)"
  echo "  Rollback:         strut $stack rollback --env $env_name"
  echo ""

  # Fire first-run hook (parity with deploy_stack — one-time init, marker-gated)
  fire_first_run_hook "$stack_dir" || warn "First-run hook failed — deploy continues"
  # Apply DB schema (opt-in, idempotent) — uses the new (green) compose project
  maybe_apply_db_schema "$stack" "$new_cmd" "$stack_dir"
  DEPLOY_STATUS="ok" fire_hook_or_warn post_deploy "$stack_dir"

  # Install declarative timers (timers.conf → systemd .service/.timer pairs).
  # No-op when the stack has no timers.conf; never abort a successful deploy.
  # Sourced lazily (not at file scope) so merely sourcing this file doesn't
  # pull in timers.sh (and transitively utils.sh) as a side effect.
  if ! declare -f timers_install >/dev/null 2>&1; then
    # shellcheck source=lib/timers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timers.sh"
  fi
  timers_install "$stack" "$stack_dir" || warn "Timer install failed — deploy continues"

  notify_event deploy.success \
    stack="$stack" \
    env="$env_name" \
    mode="blue-green" \
    active_color="$new_color" \
    services="${services_profile:-core}"
}

# bg_rollback_stack <stack> <env_file>
#
# Invoked from cmd_rollback when a .bluegreen state file exists. Flips
# active_color back and restarts the drained project. Assumes volumes of
# the drained color are still intact (we stopped without --volumes in the
# happy path).
bg_rollback_stack() {
  local stack="$1" env_file="$2"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  local env_name
  env_name="$(extract_env_name "$env_file")"

  local current previous
  current="$(_bg_read_state "$stack" "$env_name")"
  if [ -z "$current" ]; then
    fail "No blue-green state for $stack — use standard rollback"
    return 1
  fi
  previous="$(_bg_flip_color "$current")"

  local current_project previous_project
  current_project="$(_bg_project_name "$stack" "$env_name" "$current")"
  previous_project="$(_bg_project_name "$stack" "$env_name" "$previous")"
  local current_cmd previous_cmd
  current_cmd="$(_bg_compose_for_color "$stack" "$env_file" "$current" "")"
  previous_cmd="$(_bg_compose_for_color "$stack" "$env_file" "$previous" "")"

  print_banner "Blue-Green Rollback"
  log "Flipping $current → $previous"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for rollback:${NC}"
    run_cmd "Bring $previous back up"   $previous_cmd up -d --remove-orphans
    run_cmd "Wait for $previous health (timeout: ${BLUE_GREEN_HEALTH_TIMEOUT:-30}s)" echo "probe"
    run_cmd "Swap proxy $current → $previous" echo "swap"
    run_cmd "Mark $previous active"     echo "write state"
    run_cmd "Stop $current project"     $current_cmd stop
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  load_common_env
  safe_load_env "$env_file"
  env_apply_layers "$stack" "$stack_dir"
  export_volume_paths "$stack_dir"

  local compose_file="$stack_dir/docker-compose.yml"

  log "Starting $previous project..."
  # shellcheck disable=SC2086
  $previous_cmd up -d --remove-orphans

  log "Waiting for $previous health..."
  if ! _bg_wait_healthy "$stack_dir" "$previous_cmd" "$compose_file" "${BLUE_GREEN_HEALTH_TIMEOUT:-30}"; then
    warn "$previous failed health checks after rollback — aborting before the proxy swap"
    warn "  Proxy is left pointed at $current; $current has NOT been stopped"
    fail "Blue-green rollback aborted: $previous never became healthy"
    # Belt-and-suspenders: production `fail` exits, tests override to return 1.
    return 1
  fi

  log "Swapping proxy: $current → $previous"
  if ! _bg_swap_proxy "$stack" "$current_project" "$previous_project" "$env_file"; then
    warn "  Proxy is left pointed at $current; $current has NOT been stopped"
    fail "Blue-green rollback aborted: proxy swap to $previous failed"
    return 1
  fi

  # Mark active immediately after the swap succeeds, before stopping
  # $current below — same reasoning as bg_deploy_stack.
  _bg_write_state "$stack" "$env_name" "$previous" "$previous_project"

  log "Stopping $current project..."
  _bg_stop_color "$current_cmd"

  ok "Rollback complete — $previous is now active"

  notify_event deploy.rollback stack="$stack" env="$env_name" active_color="$previous"
}
