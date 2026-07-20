#!/usr/bin/env bash
# ==================================================
# lib/hooks.sh — Lifecycle hook dispatcher
# ==================================================
# Generalizes the pre-deploy hook (originally from #18) into a formal
# lifecycle system. Projects drop executable scripts into:
#
#   stacks/<stack>/hooks/<event>.sh   — per-stack hooks
#   hosts/<host>/hooks/<event>.sh     — host-scoped hooks (see cmd_provision.sh)
#
# and strut fires them at the right moment.
#
# Events (all wired):
#   pre_deploy         — before deploy_stack runs (can abort via non-zero)
#   post_deploy        — after deploy_stack succeeds (warn-only on failure)
#   pre_deploy_local   — on the CONTROLLER, before vps_release syncs the repo
#                         to the target host (can abort via non-zero)
#   post_deploy_local  — on the CONTROLLER, after vps_release finishes
#                         (warn-only on failure)
#   first_run          — once per stack on first deploy (marker-gated). The
#                        .strut-initialized marker is written ONLY when the
#                        hook exits 0 — a failed first_run leaves no marker,
#                        so it retries on the next deploy. Use
#                        `strut <stack> first-run --status` to inspect the
#                        marker and `--force` to repair (re-run) it
#                        on demand without SSHing in to delete it by hand.
#                        For "install once, reconcile always" needs (e.g. a
#                        udev rule that must be refreshed after hardware
#                        changes), write an idempotent installer and call it
#                        from BOTH first_run and post_deploy.
#   pre_backup         — before any backup runs (can abort)
#   post_backup        — after backup succeeds (warn-only)
#   pre_migrate        — before schema migration runs (can abort via non-zero)
#   post_migrate       — after migration succeeds; MIGRATE_TARGET exported (warn-only)
#   on_health_fail     — after a health check fails; HEALTH_STATUS exported (warn-only)
#   on_drift_detected  — when drift is found; DRIFTED=1 exported (warn-only)
#   pre_provision      — before a host's provision.d/ batch runs (can abort via non-zero)
#   post_provision     — after the provision.d/ batch completes (warn-only);
#                         PROVISION_HOST, PROVISION_HOST_DIR exported
#   pre_destroy        — before `destroy` tears the stack down (can abort via non-zero)
#   post_destroy       — after `destroy` succeeds (warn-only); this is the symmetric
#                         counterpart to first_run — everything first_run installs on
#                         the host (systemd units, timers, udev rules, sudoers files,
#                         routing rules, etc.), post_destroy should uninstall. On
#                         success the .strut-initialized marker is removed so a future
#                         deploy re-runs first_run cleanly.
#
# Event env vars: whatever the caller has already exported — typically
# CMD_STACK, CMD_ENV_NAME, CMD_STACK_DIR. Event-specific env vars
# (DEPLOY_STATUS, UNHEALTHY_SERVICES, MIGRATE_TARGET, HEALTH_STATUS,
# DRIFTED, etc.) are listed per call site.
#
# pre_deploy_local / post_deploy_local run on the controller (the machine
# invoking `strut release`), reading the LOCAL stack dir
# ($CLI_ROOT/stacks/<stack>), never the remote $deploy_dir — they exist for
# controller-side work (deriving env values from local repo sources,
# cross-repo validation, building artifacts to sync) that must happen
# before the target host's repo is touched. RELEASE_ENV_NAME is exported
# for both.
#
# Idempotency contract for sql/init/*.sql (wired via RUN_DB_SCHEMA_ON_DEPLOY):
#   All SQL files re-run on every deploy, so they MUST be self-idempotent:
#   use IF NOT EXISTS, CREATE OR REPLACE, guarded cron.schedule calls, etc.
#   Non-idempotent DDL will error under psql -v ON_ERROR_STOP=1.
#   The deploy continues even if schema apply fails (warn-only).
#
# Naming: hook files may use either `pre_deploy.sh` (snake_case, preferred)
# or `pre-deploy.sh` (legacy dash form, for backward compatibility with #18).

set -euo pipefail

# fire_hook <event> <stack_dir>
#
# Looks for an executable hook matching <event> under <stack_dir>/hooks/ and
# runs it with the current environment. Returns 0 if no hook found, 0 if hook
# runs successfully, or the hook's exit code on failure.
#
# Pre-* hooks: caller should propagate non-zero exit (abort action).
# Post-/on-* hooks: caller should warn but continue on non-zero.
fire_hook() {
  local event="$1"
  local stack_dir="$2"
  local hooks_dir="$stack_dir/hooks"

  # Try snake_case first, fall back to dash form (legacy)
  local hook_file=""
  local dash_event="${event//_/-}"
  for candidate in "$hooks_dir/${event}.sh" "$hooks_dir/${dash_event}.sh"; do
    if [ -f "$candidate" ]; then
      hook_file="$candidate"
      break
    fi
  done

  # No hook present — nothing to do
  [ -z "$hook_file" ] && return 0

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo -e "  ${YELLOW:-}[DRY-RUN]${NC:-} Would run ${event} hook: $hook_file"
    return 0
  fi

  log "Running ${event} hook: $hook_file"
  if bash "$hook_file"; then
    ok "${event} hook passed"
    return 0
  else
    local rc=$?
    return "$rc"
  fi
}

# fire_hook_or_warn <event> <stack_dir>
#
# Convenience wrapper for post/on hooks — runs the hook but emits a warn
# (not fail) if it exits non-zero, and always returns 0 so callers can
# continue normal flow.
fire_hook_or_warn() {
  local event="$1"
  local stack_dir="$2"

  if ! fire_hook "$event" "$stack_dir"; then
    warn "${event} hook failed (continuing)"
  fi
  return 0
}

# ── First-run hooks ──────────────────────────────────────────────────────────

# _first_run_marker_path <stack_dir>
#
# Returns the path to the .strut-initialized marker file.
# For local deploys this is inside the stack dir. For remote deploys
# the caller should resolve this path on the VPS.
_first_run_marker_path() {
  local stack_dir="$1"
  echo "$stack_dir/.strut-initialized"
}

# _first_run_hook_file <stack_dir>
#
# Echoes the path to the stack's first-run hook (snake_case preferred,
# dash-case as legacy fallback). Returns 1 (no output) if neither exists.
_first_run_hook_file() {
  local stack_dir="$1"
  local hooks_dir="$stack_dir/hooks"

  local candidate
  for candidate in "$hooks_dir/first_run.sh" "$hooks_dir/first-run.sh"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# remove_first_run_marker <stack_dir>
#
# Deletes the .strut-initialized marker (if present) so a future deploy
# re-runs the first_run hook cleanly. No-op (returns 0) if the marker is
# already absent.
remove_first_run_marker() {
  local stack_dir="$1"
  local marker
  marker=$(_first_run_marker_path "$stack_dir")
  [ -f "$marker" ] && rm -f "$marker" && log "Removed first-run marker: $marker"
  return 0
}

# first_run_needed <stack_dir>
#
# Returns 0 if a first-run hook exists AND the stack has not been initialized
# (marker file is absent). Returns 1 otherwise (no hook or already initialized).
first_run_needed() {
  local stack_dir="$1"

  _first_run_hook_file "$stack_dir" >/dev/null || return 1

  # Check if already initialized
  local marker
  marker=$(_first_run_marker_path "$stack_dir")
  [ -f "$marker" ] && return 1

  return 0
}

# first_run_status <stack_dir>
#
# Reports whether the stack has a first-run hook and whether it has been
# initialized. Prints human-readable lines; always returns 0.
first_run_status() {
  local stack_dir="$1"
  local hook_file
  local marker
  marker=$(_first_run_marker_path "$stack_dir")

  if hook_file=$(_first_run_hook_file "$stack_dir"); then
    echo "first_run hook: $hook_file"
  else
    echo "first_run hook: (none)"
  fi

  echo "marker: $marker"
  if [ -f "$marker" ]; then
    local initialized_line
    initialized_line=$(grep '^initialized=' "$marker" 2>/dev/null || true)
    echo "initialized: yes (${initialized_line#initialized=})"
  else
    echo "initialized: no"
  fi

  return 0
}

# fire_first_run_hook <stack_dir> [force]
#
# Runs the first-run hook if it exists and the stack hasn't been initialized.
# On success, creates the .strut-initialized marker with a timestamp.
# Returns 0 if no hook needed, 0 on success, or non-zero on hook failure.
#
# force: when truthy, ignores the "already initialized" gate and re-runs
# the hook — used for repair/reconciliation (e.g. after hardware changes).
# Still no-ops (with a warning) when no first_run hook exists at all.
fire_first_run_hook() {
  local stack_dir="$1"
  local force="${2:-}"

  if [ -n "$force" ]; then
    if ! _first_run_hook_file "$stack_dir" >/dev/null; then
      warn "No first_run hook found for this stack — nothing to force-run"
      return 0
    fi
    rm -f "$(_first_run_marker_path "$stack_dir")"
  elif ! first_run_needed "$stack_dir"; then
    return 0
  fi

  log "First-run hook detected — running one-time initialization..."
  if fire_hook first_run "$stack_dir"; then
    local marker
    marker=$(_first_run_marker_path "$stack_dir")
    echo "initialized=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker"
    ok "First-run hook completed — stack initialized"
    return 0
  else
    local rc=$?
    error "First-run hook failed (exit $rc)"
    warn "Stack NOT marked as initialized — hook will re-run on next deploy"
    return "$rc"
  fi
}
