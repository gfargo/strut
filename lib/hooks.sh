#!/usr/bin/env bash
# ==================================================
# lib/hooks.sh — Lifecycle hook dispatcher
# ==================================================
# Generalizes the pre-deploy hook (originally from #18) into a formal
# lifecycle system. Projects drop executable scripts into:
#
#   stacks/<stack>/hooks/<event>.sh
#
# and strut fires them at the right moment.
#
# Events:
#   pre_deploy         — before deploy_stack runs (can abort via non-zero)
#   post_deploy        — after deploy_stack succeeds (warn-only on failure)
#   pre_backup         — before any backup runs (can abort)
#   post_backup        — after backup succeeds (warn-only)
#   on_health_fail     — after a health check fails (warn-only)
#   on_drift_detected  — when drift is found (warn-only)
#
# Event env vars: whatever the caller has already exported — typically
# CMD_STACK, CMD_ENV_NAME, CMD_STACK_DIR. Event-specific env vars
# (DEPLOY_STATUS, UNHEALTHY_SERVICES, etc.) are listed per call site.
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
