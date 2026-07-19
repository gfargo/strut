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
#   first_run          — once per stack on first deploy (marker-gated)
#   pre_backup         — before any backup runs (can abort)
#   post_backup        — after backup succeeds (warn-only)
#   pre_migrate        — before schema migration runs (can abort via non-zero)
#   post_migrate       — after migration succeeds; MIGRATE_TARGET exported (warn-only)
#   on_health_fail     — after a health check fails; HEALTH_STATUS exported (warn-only)
#   on_drift_detected  — when drift is found; DRIFTED=1 exported (warn-only)
#   pre_provision      — before a host's provision.d/ batch runs (can abort via non-zero)
#   post_provision     — after the provision.d/ batch completes (warn-only);
#                         PROVISION_HOST, PROVISION_HOST_DIR exported
#
# Event env vars: whatever the caller has already exported — typically
# CMD_STACK, CMD_ENV_NAME, CMD_STACK_DIR. Event-specific env vars
# (DEPLOY_STATUS, UNHEALTHY_SERVICES, MIGRATE_TARGET, HEALTH_STATUS,
# DRIFTED, etc.) are listed per call site.
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

# first_run_needed <stack_dir>
#
# Returns 0 if a first-run hook exists AND the stack has not been initialized
# (marker file is absent). Returns 1 otherwise (no hook or already initialized).
first_run_needed() {
  local stack_dir="$1"
  local hooks_dir="$stack_dir/hooks"

  # Check if a first-run hook exists
  local hook_file=""
  for candidate in "$hooks_dir/first_run.sh" "$hooks_dir/first-run.sh"; do
    if [ -f "$candidate" ]; then
      hook_file="$candidate"
      break
    fi
  done
  [ -z "$hook_file" ] && return 1

  # Check if already initialized
  local marker
  marker=$(_first_run_marker_path "$stack_dir")
  [ -f "$marker" ] && return 1

  return 0
}

# fire_first_run_hook <stack_dir>
#
# Runs the first-run hook if it exists and the stack hasn't been initialized.
# On success, creates the .strut-initialized marker with a timestamp.
# Returns 0 if no hook needed, 0 on success, or non-zero on hook failure.
fire_first_run_hook() {
  local stack_dir="$1"

  if ! first_run_needed "$stack_dir"; then
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
