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
# State: stacks/<stack>/.bluegreen records the currently-active color so
# the next deploy flips to the opposite slot. A rollback reads this file
# and flips back.
#
# Helpers are underscore-prefixed and intentionally small so tests can
# stub them individually.

set -euo pipefail

# ── State file ────────────────────────────────────────────────────────────────

# _bg_state_file <stack>
_bg_state_file() {
  local stack="$1"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  echo "$cli_root/stacks/$stack/.bluegreen"
}

# _bg_read_state <stack> — echoes the current active color or empty string.
# Parses a tiny `active_color=<blue|green>` file (not JSON, to avoid a
# jq dependency on the fast path).
_bg_read_state() {
  local stack="$1"
  local f
  f="$(_bg_state_file "$stack")"
  [ -f "$f" ] || { echo ""; return 0; }
  awk -F= '$1 == "active_color" { print $2; exit }' "$f" | tr -d '[:space:]"'
}

# _bg_write_state <stack> <color> [project]
_bg_write_state() {
  local stack="$1" color="$2" project="${3:-}"
  local f
  f="$(_bg_state_file "$stack")"
  mkdir -p "$(dirname "$f")"
  {
    echo "active_color=$color"
    [ -n "$project" ] && echo "active_project=$project"
    echo "updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$f"
}

# _bg_clear_state <stack>
_bg_clear_state() {
  local stack="$1"
  rm -f "$(_bg_state_file "$stack")"
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

# _bg_pick_colors <stack>
#
# Echoes two whitespace-separated tokens: "<old_color> <new_color>".
# First deploy (no state): "none blue" — the green slot is empty, new
# color goes to blue.
_bg_pick_colors() {
  local stack="$1"
  local current
  current="$(_bg_read_state "$stack")"
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
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local compose_file="$cli_root/stacks/$stack/docker-compose.yml"
  local env_name
  env_name="$(extract_env_name "$env_file")"
  local project
  project="$(_bg_project_name "$stack" "$env_name" "$color")"

  local cmd="$(_docker_sudo)docker compose --env-file $env_file --project-name $project -f $compose_file"
  [ -n "$services_profile" ] && cmd="$cmd --profile $services_profile"
  echo "$cmd"
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
  log "Starting green project"
  # shellcheck disable=SC2086
  $compose_cmd up -d --remove-orphans
}

# _bg_wait_healthy <stack_dir> <compose_cmd> <compose_file> [timeout_seconds]
#
# Polls health_run_all (scoped to the green compose project) until it
# reports healthy or the timeout elapses. Returns 0 healthy, 1 on timeout.
#
# We snapshot HEALTH_* globals across the probe so the suite's own state
# doesn't leak into the caller.
_bg_wait_healthy() {
  local stack_dir="$1" compose_cmd="$2" compose_file="$3"
  local timeout="${4:-${BLUE_GREEN_HEALTH_TIMEOUT:-30}}"
  local interval=3
  local elapsed=0

  log "Waiting for green health (timeout: ${timeout}s)"
  while [ "$elapsed" -lt "$timeout" ]; do
    # Re-source health.sh into a subshell so the probe's counters don't
    # clobber the caller's state. We only care about the exit code.
    if ( health_run_all "$(basename "$stack_dir")" "$compose_cmd" "$compose_file" --json >/dev/null 2>&1 ); then
      ok "green healthy"
      return 0
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
  # blue-green (pluggable upstream). The warn makes that contract visible.
  local proxy="${REVERSE_PROXY:-nginx}"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local compose_file="$cli_root/stacks/$stack/docker-compose.yml"
  local new_cmd
  new_cmd="$(_docker_sudo)docker compose --env-file $env_file --project-name $new_project -f $compose_file"

  warn "No BLUE_GREEN_PROXY_HOOK set — falling back to $proxy reload in $new_project"
  warn "  For true atomic swap, set BLUE_GREEN_PROXY_HOOK in strut.conf"
  case "$proxy" in
    nginx)
      # shellcheck disable=SC2086
      $new_cmd exec -T "$proxy" nginx -s reload 2>/dev/null && ok "nginx reloaded on $new_project" \
        || warn "nginx reload failed (proxy may not be running yet)"
      ;;
    caddy)
      # shellcheck disable=SC2086
      $new_cmd exec -T "$proxy" caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
        && ok "Caddy reloaded on $new_project" \
        || warn "Caddy reload failed (proxy may not be running yet)"
      ;;
    *)
      warn "Unknown proxy '$proxy' — skipping reload"
      ;;
  esac
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
# Stops the old color's project. Volumes are preserved (no --volumes) so
# rollback can bring the same color back up warm.
_bg_stop_color() {
  local compose_cmd="$1"
  # shellcheck disable=SC2086
  $compose_cmd down --remove-orphans 2>/dev/null || true
}

# _bg_teardown_failed_color <compose_cmd>
#
# Invoked when health probes for a freshly-started color never succeed.
# Same as _bg_stop_color today but kept as a distinct helper so failure
# cleanup can grow (container logs capture, snapshot, etc.) without
# bloating the success path.
_bg_teardown_failed_color() {
  local compose_cmd="$1"
  warn "Tearing down failed green color"
  # shellcheck disable=SC2086
  $compose_cmd down --remove-orphans --volumes 2>/dev/null || true
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

  [ -d "$stack_dir" ]    || fail "Stack not found: $stack (looked in $stack_dir)"
  [ -f "$compose_file" ] || fail "Compose file not found: $compose_file"
  [ -f "$env_file" ]     || fail "Env file not found: $env_file"

  # Source env + validate required vars — same contract as deploy_stack.
  set -a; source "$env_file"; set +a
  export_volume_paths "$stack_dir"

  local required_vars_file="$stack_dir/required_vars"
  if [ -f "$required_vars_file" ]; then
    while IFS= read -r var || [ -n "$var" ]; do
      [ -z "$var" ] && continue
      val="$(eval echo "\${${var}:-}")"
      [ -n "$val" ] || fail "Missing required env var: $var (check $env_file)"
    done < "$required_vars_file"
  fi

  local env_name
  env_name="$(extract_env_name "$env_file")"

  # Decide colors
  local pick old_color new_color
  pick="$(_bg_pick_colors "$stack")"
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
  log "[1/9] Pre-flight checks..."
  require_cmd docker "Install with: curl -fsSL https://get.docker.com | bash"
  docker compose version &>/dev/null || fail "Docker Compose plugin not found"
  ok "Pre-flight checks passed"

  # Pre-deploy validation (reuse standard path's contract)
  if [ "${SKIP_VALIDATION:-false}" != "true" ] && [ "${PRE_DEPLOY_VALIDATE:-true}" = "true" ]; then
    log "[2/9] Pre-deploy validation..."
    source "$cli_root/lib/cmd_validate.sh"
    export CMD_STACK="$stack" CMD_STACK_DIR="$stack_dir" CMD_ENV_FILE="$env_file" CMD_ENV_NAME="$env_name"
    cmd_validate 2>/dev/null || fail "Pre-deploy validation failed — fix and retry: strut $stack validate --env $env_name"

    if [ "${PRE_DEPLOY_HOOKS:-true}" = "true" ]; then
      fire_hook pre_deploy "$stack_dir" || fail "pre_deploy hook failed — aborting deploy"
    fi
    ok "Pre-deploy validation passed"
  elif [ "${SKIP_VALIDATION:-false}" = "true" ]; then
    warn "Pre-deploy validation skipped (--skip-validation)"
  fi

  # Dry-run plan — stop before any side effects.
  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for blue-green deploy:${NC}"
    run_cmd "Authenticate with registry" echo "registry auth"
    run_cmd "Pull images for $new_color" $new_cmd pull
    run_cmd "Start $new_color project"   $new_cmd up -d --remove-orphans
    run_cmd "Wait for $new_color health (timeout: ${BLUE_GREEN_HEALTH_TIMEOUT:-30}s)" echo "probe"
    run_cmd "Swap proxy $old_color → $new_color" echo "swap"
    run_cmd "Drain $old_color (${BLUE_GREEN_DRAIN:-60}s)" echo "drain"
    if [ "$old_color" != "none" ]; then
      run_cmd "Stop $old_color project" $old_cmd down --remove-orphans
    fi
    run_cmd "Mark $new_color as active" echo "write state"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # Registry auth (shared with standard deploy).
  log "[3/9] Authenticating with registry..."
  registry_login

  # Save rollback snapshot of the **current** color before we touch anything.
  # Restore paths: standard rollback restores images; blue-green rollback
  # flips the .bluegreen active_color and brings the old project back up.
  source "$cli_root/lib/rollback.sh"
  if [ "$old_color" != "none" ]; then
    rollback_save_snapshot "$stack" "$old_cmd" "$env_name" || true
  fi

  # Stand up green
  log "[4/9] Starting $new_color project alongside $old_color..."
  _bg_start_color "$new_cmd"

  # Health gate
  log "[5/9] Waiting for $new_color health..."
  if ! _bg_wait_healthy "$stack_dir" "$new_cmd" "$compose_file" "${BLUE_GREEN_HEALTH_TIMEOUT:-30}"; then
    warn "green failed health checks — tearing down and aborting"
    _bg_teardown_failed_color "$new_cmd"
    notify_event deploy.failed stack="$stack" env="$env_name" reason="green_unhealthy"
    fail "Blue-green deploy aborted: $new_color never became healthy (old color untouched)"
    # Belt-and-suspenders: in production `fail` exits, but tests override it
    # to `return 1`, so make the abort explicit either way.
    return 1
  fi

  # Swap proxy
  log "[6/9] Swapping reverse proxy: $old_color → $new_color"
  _bg_swap_proxy "$stack" "$old_project" "$new_project" "$env_file"

  # Drain
  if [ "$old_color" != "none" ]; then
    log "[7/9] Draining $old_color (${BLUE_GREEN_DRAIN:-60}s)..."
    _bg_drain "${BLUE_GREEN_DRAIN:-60}"

    log "[8/9] Stopping $old_color project..."
    _bg_stop_color "$old_cmd"
  else
    log "[7/9] Skipping drain (no previous color)"
    log "[8/9] Skipping stop (no previous color)"
  fi

  # Mark active
  log "[9/9] Marking $new_color as active"
  _bg_write_state "$stack" "$new_color" "$new_project"

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✓  Blue-green deploy complete (stack: $stack, active: $new_color)${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "  Active project:   $new_project"
  [ "$old_color" != "none" ] && echo "  Previous project: $old_project (stopped, volumes retained)"
  echo "  Rollback:         strut $stack rollback --env $env_name"
  echo ""

  DEPLOY_STATUS="ok" fire_hook_or_warn post_deploy "$stack_dir"
  notify_event deploy.success \
    stack="$stack" \
    env="$env_name" \
    mode="blue-green" \
    active_color="$new_color" \
    services="${services_profile:-core}"
}

# ── Rollback support ──────────────────────────────────────────────────────────

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
  current="$(_bg_read_state "$stack")"
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
    run_cmd "Swap proxy $current → $previous" echo "swap"
    run_cmd "Stop $current project"     $current_cmd down --remove-orphans
    run_cmd "Mark $previous active"     echo "write state"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  set -a; source "$env_file"; set +a
  export_volume_paths "$stack_dir"

  log "Starting $previous project..."
  # shellcheck disable=SC2086
  $previous_cmd up -d --remove-orphans

  log "Swapping proxy: $current → $previous"
  _bg_swap_proxy "$stack" "$current_project" "$previous_project" "$env_file"

  log "Stopping $current project..."
  _bg_stop_color "$current_cmd"

  _bg_write_state "$stack" "$previous" "$previous_project"
  ok "Rollback complete — $previous is now active"

  notify_event deploy.rollback stack="$stack" env="$env_name" active_color="$previous"
}
