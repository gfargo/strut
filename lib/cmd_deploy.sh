#!/usr/bin/env bash
# ==================================================
# cmd_deploy.sh — Deploy, update, release, status, prune handlers
# ==================================================

set -euo pipefail

# _deploy_volguard <stack> <env_file> <confirm_data_move>
#
# Detects data-destructive changes (volume-defining var modifications,
# COMPOSE_PROJECT_NAME changes, named-volume renames) by comparing the
# local env file against the remote VPS env file. Aborts — or in DRY_RUN
# mode, warns — when destructive changes are found and --confirm-data-move
# was not passed.
#
# This is a pure diff-based guard (no SSH path probing). It requires
# VPS_HOST to be set; if not (local-only stacks), the guard is skipped.
# If VPS_HOST IS set but SSH cannot reach the host, the guard fails loud
# (aborts the deploy) rather than silently behaving like "nothing to check" —
# unless DRY_RUN or --confirm-data-move is in play, matching the guard's
# other abort path.
#
# KNOWN GAP: this diffs the raw base env_file (grep/cat, not exported env),
# so it does not see overrides from the tracked per-host layer
# (env_apply_layers / stacks/<stack>/env/hosts/<alias>.env). A volume-
# defining var overridden only in the host layer won't trigger this guard.
# Tracked for the layered-env umbrella (#179).
_deploy_volguard() {
  local stack="$1"
  local env_file="$2"
  local confirm_data_move="${3:-false}"

  # Only run when we have a VPS target to diff against
  [ -f "$env_file" ] || return 0
  # Read VPS_HOST from env file without sourcing (safe parsing)
  local _vps_host
  _vps_host=$(grep -E '^\s*(export\s+)?VPS_HOST=' "$env_file" 2>/dev/null | tail -1 | sed 's/^[^=]*=//' | tr -d '"'"'" || true)
  [ -n "$_vps_host" ] || return 0

  # Locate the stack compose file
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  local compose_file="$stack_dir/docker-compose.yml"
  [ -f "$compose_file" ] || return 0

  local local_compose_content
  local_compose_content=$(cat "$compose_file")

  # Fetch the remote env content — reuse diff_fetch_remote from diff.sh.
  local deploy_dir; deploy_dir=$(resolve_deploy_dir)
  local env_name="${CMD_ENV_NAME:-prod}"
  local remote_env_path

  # Use the same remote-path resolution used by cmd_diff. Pass the actual
  # local env file's basename (not a reconstructed ".$env_name.env") so a
  # git-committed ".<env>.enc.env" (strut#178 secrets-filter) diffs against
  # its real checked-out path on the VPS instead of silently finding nothing.
  local env_basename; env_basename=$(basename -- "$env_file")
  if declare -F _secrets_resolve_remote_path >/dev/null 2>&1; then
    remote_env_path=$(_secrets_resolve_remote_path "$deploy_dir" "$env_name" "$env_basename")
  else
    remote_env_path="$deploy_dir/$env_basename"
  fi

  local remote_env_content rc=0
  remote_env_content=$(diff_fetch_remote "$remote_env_path" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 2 ]; then
    if [ "$DRY_RUN" = "true" ] || [ "$confirm_data_move" = "true" ]; then
      warn "Cannot verify remote state for '$stack': SSH to $_vps_host failed. Check VPS_HOST/VPS_PORT/VPS_SSH_KEY."
      return 0
    fi
    fail "Cannot verify remote state for '$stack': SSH to $_vps_host failed. Check VPS_HOST/VPS_PORT/VPS_SSH_KEY, or re-run with --confirm-data-move."
    return 1
  fi
  [ -n "$remote_env_content" ] || return 0

  # Compute env diff and destructive subset
  local local_env_content
  local_env_content=$(cat "$env_file")

  local env_diff destructive_diff remote_compose_content volume_renames
  env_diff=$(diff_env_content "$local_env_content" "$remote_env_content")

  # Also fetch remote compose for named-volume rename detection
  local remote_compose_path="$deploy_dir/stacks/$stack/docker-compose.yml"
  remote_compose_content=$(diff_fetch_remote "$remote_compose_path" 2>/dev/null) || remote_compose_content=""
  volume_renames=$(diff_detect_volume_renames "$local_compose_content" "${remote_compose_content:-}" 2>/dev/null) || volume_renames=""

  destructive_diff=$(diff_detect_destructive "$env_diff" "$local_compose_content")

  # Nothing dangerous — continue
  if [ -z "$destructive_diff" ] && [ -z "$volume_renames" ]; then
    return 0
  fi

  # Show the problem
  local RED="${RED:-\033[0;31m}"
  local NC="${NC:-\033[0m}"
  echo "" >&2
  printf '%s\n' "${RED}⚠  strut: Data-destructive changes detected${NC}" >&2
  echo "" >&2
  if [ -n "$destructive_diff" ]; then
    _diff_render_destructive_text "$destructive_diff" >&2
  fi
  if [ -n "$volume_renames" ]; then
    _diff_render_destructive_text "$volume_renames" >&2
  fi
  echo "" >&2
  printf "   Containers may start with a blank database if you proceed.\n" >&2
  printf "   Re-run with --confirm-data-move to override this check.\n" >&2
  echo "" >&2

  if [ "$DRY_RUN" = "true" ]; then
    # Dry-run: warn but don't abort
    warn "DRY-RUN: would abort here without --confirm-data-move"
    return 0
  fi

  if [ "$confirm_data_move" = "true" ]; then
    warn "Proceeding with data-destructive changes (--confirm-data-move passed)"
    return 0
  fi

  # Interactive TTY: give the operator a chance to confirm
  if [ -t 0 ] && declare -F confirm >/dev/null 2>&1; then
    if confirm "Proceed anyway? (data may be lost)"; then
      return 0
    fi
  fi

  fail "Deploy aborted: data-destructive changes require --confirm-data-move"
  return 1
}

_usage_deploy() {
  echo ""
  echo "Usage: strut <stack> deploy [--env <name>] [--services <profile>]"
  echo "                            [--local | --require-remote] [--no-sync] [--no-migrate]"
  echo "                            [--pull-only] [--skip-validation] [--blue-green | --standard]"
  echo "                            [--dry-run] [--confirm-data-move]"
  echo ""
  echo "Deploy a stack. The target comes from the stack's topology, not from"
  echo "where you type this: a stack mapped to a VPS deploys to that VPS, and"
  echo "everything else deploys against the local Docker daemon."
  echo ""
  echo "  Remote target — syncs the repo, runs migrations, pulls images,"
  echo "  restarts services, health-checks, and rolls back if unhealthy."
  echo "  ('release' is an alias for exactly this.)"
  echo ""
  echo "  Local target — pulls images, creates data directories, stops"
  echo "  existing containers, and starts services."
  echo ""
  echo "Flags:"
  echo "  --env <name>         Environment (reads .<name>.env)"
  echo "  --services <profile> Service profile (messaging|ui|full)"
  echo "  --local              Deploy to the LOCAL Docker daemon even when the"
  echo "                       stack maps to a VPS (alias: --force-local)"
  echo "  --require-remote     Fail if the stack resolves to no VPS, instead of"
  echo "                       deploying locally (use in CI; 'release' implies it)"
  echo "  --pull-only          Pull images without restarting containers"
  echo "  --no-sync            Remote only: skip the git sync, deploy the"
  echo "                       checkout already on the host"
  echo "  --no-migrate         Remote only: skip the migration steps"
  echo "  --strict             Remote only: halt the deploy if a migration fails"
  echo "  --no-rollback        Remote only: don't auto-roll-back on health failure"
  echo "  --backup-first       Remote only: back up databases before deploying"
  echo "  --skip-validation    Skip pre-deploy config validation and hooks"
  echo "  --skip-health-gate   Skip post-up health polling (for one-shot/migration stacks)"
  echo "  --force-unlock       Break an existing deploy lock before acquiring"
  echo "  --no-lock            Skip lock acquisition (advanced; recovery only)"
  echo "  --blue-green         Stand up new version alongside current, health-gate,"
  echo "                       swap proxy, drain old (overrides DEPLOY_MODE)"
  echo "  --standard           Force in-place deploy (overrides DEPLOY_MODE)"
  echo "  --force-clean        Allow git clean to delete untracked VPS files"
  echo "                       (bypass data-loss guard; use with caution)"
  echo "  --confirm-data-move  Proceed even when volume-defining vars or named"
  echo "                       volumes changed (use with care — data may be lost)"
  echo "  --dry-run            Show execution plan without making changes"
  echo ""
  echo "Related commands:"
  echo "  release              Alias for 'deploy --require-remote' (kept for existing scripts)"
  echo "  update               Sync the repo on the VPS without restarting anything"
  echo "  stop                 Stop running containers"
  echo "  health               Run health checks after deploy"
  echo "  rollback             Restore previous deploy (blue-green: flips active color)"
  echo ""
  echo "Examples:"
  echo "  strut my-stack deploy --env prod"
  echo "  strut my-stack deploy --env prod --services full"
  echo "  strut my-stack deploy --env prod --dry-run"
  echo "  strut my-stack deploy --env prod --no-sync      # restart, don't ship new code"
  echo "  strut my-stack deploy --env prod --local        # local Docker daemon"
  echo "  strut my-stack deploy --env prod --blue-green"
  echo ""
}

_usage_health() {
  echo ""
  echo "Usage: strut <stack> health [--env <name>] [--services <profile>] [--json]"
  echo ""
  echo "Run health checks: Docker daemon, containers, services, network, databases."
  echo ""
  echo "Flags:"
  echo "  --env <name>         Environment (reads .<name>.env)"
  echo "  --services <profile> Service profile"
  echo "  --json               Output results as JSON"
  echo ""
  echo "Examples:"
  echo "  strut my-stack health --env prod"
  echo "  strut my-stack health --env prod --json"
  echo ""
}

# cmd_update (no args — reads CMD_*)
cmd_update() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  validate_env_file "$env_file" VPS_HOST GH_PAT
  vps_update_repo "$stack" "$env_file"
}

# cmd_rebuild [--no-cache] [--pull] [--confirm-data-move] (reads CMD_*)
# Builds images and restarts services. Equivalent to deploy with BUILD_MODE=local.
cmd_rebuild() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local services="$CMD_SERVICES"

  # Parse rebuild-specific flags
  local no_cache=false
  local pull_base=false
  local confirm_data_move=false
  local platform_flag=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-cache) no_cache=true; shift ;;
      --pull) pull_base=true; shift ;;
      --confirm-data-move) confirm_data_move=true; shift ;;
      --platform) platform_flag="$2"; shift 2 ;;
      --platform=*) platform_flag="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  # Force BUILD_MODE=local for this deploy, with optional flags
  export BUILD_MODE="local"
  if [ "$no_cache" = "true" ]; then
    export BUILD_ARGS="${BUILD_ARGS:+$BUILD_ARGS }--no-cache"
  fi
  if [ "$pull_base" = "true" ]; then
    export BUILD_PULL="true"
  fi
  # --platform overrides PLATFORMS from services.conf for this rebuild only
  [ -n "$platform_flag" ] && export PLATFORMS="$platform_flag"

  # Guard: detect data-destructive env changes before rebuilding
  _deploy_volguard "$stack" "$env_file" "$confirm_data_move" || return 1
  diff_warn_env_divergence "$stack" "$env_file" "${CMD_STACK_DIR:-$CLI_ROOT/stacks/$stack}"

  # Delegate to the standard deploy pipeline
  deploy_stack "$stack" "$env_file" "$services"
}

_usage_rebuild() {
  echo ""
  echo "Usage: strut <stack> rebuild [--env <name>] [--no-cache] [--pull] [--platform <list>] [--dry-run] [--confirm-data-move]"
  echo ""
  echo "Build images on target and restart services."
  echo "Equivalent to deploy with BUILD_MODE=local."
  echo ""
  echo "Options:"
  echo "  --env <name>           Environment (reads .<name>.env)"
  echo "  --no-cache             Build without using cache"
  echo "  --pull                 Pull base images before building"
  echo "  --platform <list>      Comma-separated docker platforms (e.g. linux/amd64,linux/arm64)."
  echo "                         Single platform ≠ host arch: cross-arch build via buildx --load."
  echo "                         More than one: multi-arch build via buildx --push (needs a registry)."
  echo "                         Overrides PLATFORMS from services.conf for this run."
  echo "  --dry-run              Show execution plan without running"
  echo "  --confirm-data-move    Proceed even when volume-defining vars changed"
  echo ""
  echo "Examples:"
  echo "  strut hub rebuild --env prod"
  echo "  strut hub rebuild --env prod --no-cache"
  echo "  strut hub rebuild --env prod --platform linux/arm64,linux/amd64"
  echo ""
}

# cmd_release [--strict] [--confirm-data-move] [--no-rollback] [--backup-first]
#
# Alias for `deploy`. Since deploy resolves its target from the stack's
# topology, `deploy` on a VPS-mapped stack now runs exactly the pipeline
# `release` always ran — so the two verbs would be indistinguishable. Rather
# than keep both in the help and re-create the ambiguity strut#415 was filed
# about, `release` stays a permanently-supported alias: every existing script,
# runbook, and CI job keeps working, unchanged and unwarned.
#
# The one thing it does NOT inherit is deploy's willingness to fall back to a
# local deploy. `release` has always meant "ship to the VPS", so a stack that
# resolves nowhere remote is a config error, not an invitation to deploy to the
# local Docker daemon. That strictness is now spelled --require-remote, which
# makes `release` exactly `deploy --require-remote` — the last behavioural
# difference between the two verbs expressed as a flag rather than a name.
cmd_release() {
  cmd_deploy --require-remote "$@"
}

# cmd_deploy [--pull-only] [--skip-validation] [positional...] (reads CMD_*)
cmd_deploy() {
  local stack="$CMD_STACK"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"

  # Parse deploy-specific flags
  local pull_only=false
  local skip_validation=false
  local skip_health_gate=false
  local force_unlock=false
  local skip_lock=false
  local force_local=false
  local require_remote=false
  local confirm_data_move=false
  # Release-pipeline flags — meaningful only on the remote path below, where
  # `deploy` runs the full sync → migrate → deploy → health sequence. Parsed
  # unconditionally so `deploy` accepts everything `release` ever did.
  local auto_rollback=true
  local backup_first=false
  # Mode: honor DEPLOY_MODE config default; --blue-green / --standard on the
  # CLI always wins. `mode_flag=""` means "not overridden — use config".
  local mode_flag=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pull-only) pull_only=true; shift ;;
      --skip-validation) skip_validation=true; shift ;;
      --skip-health-gate) skip_health_gate=true; shift ;;
      --force-unlock) force_unlock=true; shift ;;
      --no-lock) skip_lock=true; shift ;;
      # --force-local is the original spelling, kept working forever; --local
      # is the one we document, since the flag states intent, not force.
      --local|--force-local) force_local=true; shift ;;
      --require-remote) require_remote=true; shift ;;
      --blue-green) mode_flag="blue-green"; shift ;;
      --standard)   mode_flag="standard";   shift ;;
      --confirm-data-move) confirm_data_move=true; shift ;;
      --strict) export MIGRATION_FAILURE_MODE="halt"; shift ;;
      --no-rollback) auto_rollback=false; shift ;;
      --backup-first) backup_first=true; shift ;;
      --no-sync) export RELEASE_SKIP_SYNC=true; shift ;;
      --no-migrate) export RELEASE_SKIP_MIGRATE=true; shift ;;
      *) shift ;;
    esac
  done
  local deploy_mode="${mode_flag:-${DEPLOY_MODE:-standard}}"

  # Export for deploy_stack to read
  export SKIP_VALIDATION="$skip_validation"
  export DEPLOY_SKIP_HEALTH_GATE="$skip_health_gate"

  # ── Remote requirement ─────────────────────────────────────────────────────
  # --require-remote asserts "this stack MUST resolve to a VPS", turning a
  # topology that resolves nowhere into a hard error instead of a local deploy.
  #
  # This exists because the local fallback is a footgun in exactly the places
  # nobody is watching: on a CI runner or under the MCP server, a stack whose
  # VPS_HOST fails to resolve would deploy to the runner's own Docker daemon
  # and exit 0 — a silent no-op that reports success. Callers that can never
  # legitimately mean "here" pass this flag. It's also what makes `release`
  # expressible as plain deploy (see cmd_release).
  if [ "$require_remote" = "true" ]; then
    if [ "$force_local" = "true" ]; then
      fail "--require-remote and --local are contradictory — pick one"
      return 1
    fi
    validate_env_file "$env_file" VPS_HOST || return 1
  fi

  # ── Target resolution ──────────────────────────────────────────────────────
  # `deploy` means "deploy this stack" — the stack's topology decides WHERE,
  # exactly as status/health/logs/rollback already do via should_dispatch_remote.
  #
  # It used to mean "deploy on whatever machine I'm typing on", with `release`
  # as a separate top-level verb for the VPS. But those two were never peers:
  # release is the orchestrator and deploy is the primitive it SSHes in to run
  # (steps 4 and 5 of vps_release are literally `./strut <stack> deploy`).
  # Presenting a primitive and its own orchestrator as sibling verbs, with no
  # cue which was which, is what made "deploy didn't reach my VPS" a repeatable
  # mistake — one the old code met with a warning you could hit `y` past.
  # `release` still works and lands here. (strut#415)
  #
  # --local is the escape hatch. The remote path is skipped when we ARE the
  # target (STRUT_REMOTE_EXEC / hostname match), which is what stops the
  # inner deploy invoked by the pipeline below from dispatching again.
  if [ "$force_local" != "true" ] && should_dispatch_remote; then
    validate_env_file "$env_file" VPS_HOST
    if [ "$pull_only" = "true" ]; then
      # --pull-only is one step, not the whole pipeline — run just that step on
      # the target rather than promoting it into a full release.
      local _remote_args="deploy --pull-only"
      [ -n "$services" ] && _remote_args="$_remote_args --services $services"
      run_remote_strut "$stack" "$env_name" "$_remote_args"
      return $?
    fi
    _deploy_volguard "$stack" "$env_file" "$confirm_data_move" || return 1
    diff_warn_env_divergence "$stack" "$env_file" "${CMD_STACK_DIR:-$CLI_ROOT/stacks/$stack}"
    vps_release "$stack" "$env_file" "$services" "$auto_rollback" "$backup_first"
    return $?
  fi

  # ── Concurrency lock ─────────────────────────────────────────────────────
  # Prevents two deploys racing against the same stack/env. Honor --no-lock
  # escape hatch for specialized recovery flows, and --force-unlock to break
  # stale locks from a previous crashed deploy.
  if [ "$skip_lock" != "true" ] && [ "$DRY_RUN" != "true" ]; then
    local _env_key="${env_name:-default}"
    local _lock_nonce=""
    if [ "$force_unlock" = "true" ]; then
      warn "Breaking any existing deploy lock (--force-unlock)"
      lock_force_break_local "$stack" "$_env_key" || true
    fi
    if ! _lock_nonce=$(lock_acquire_local "$stack" "$_env_key" "deploy"); then
      if lock_is_stale_local "$stack" "$_env_key"; then
        warn "Existing deploy lock is stale (owner process dead) — auto-breaking"
        lock_force_break_local "$stack" "$_env_key" || true
        if ! _lock_nonce=$(lock_acquire_local "$stack" "$_env_key" "deploy"); then
          fail "Deploy lock held — aborting (could not reacquire after breaking stale lock)"
        fi
      else
        warn "Re-run with --force-unlock if you're sure the previous deploy is gone"
        fail "Deploy lock held — aborting"
      fi
    fi
    # Ensure lock is released no matter how we exit. Register with the
    # entrypoint's unified cleanup chain so we don't clobber other traps.
    # The nonce ensures this cleanup only removes the lock THIS process
    # created — if it was force-broken and re-acquired by a different
    # deploy in the meantime, the release becomes a safe no-op (strut#383).
    if declare -F strut_register_cleanup >/dev/null; then
      strut_register_cleanup "lock_release_local '$stack' '$_env_key' '$_lock_nonce'"
    fi
  fi

  # Past the dispatch above, a local deploy of a VPS-mapped stack can only be a
  # deliberate --local. Say where the containers are actually going — the stack
  # normally lives elsewhere, so the local daemon is the surprising answer — but
  # state it and continue: this was asked for explicitly. (The old code warned
  # and then offered a y/N prompt here, which STRUT_YES=1 auto-confirmed.)
  if [ "$force_local" = "true" ] && [ -n "${VPS_HOST:-}" ] && ! is_running_on_vps; then
    warn "Deploying '$stack' to the LOCAL Docker daemon (--local); its usual target is $VPS_HOST"
  fi

  # Guard against a silent local fallback (strut#488). VPS_HOST is resolved
  # from the env-file cascade plus the [stacks]->[hosts] topology layer in
  # strut.conf — NOT from services.conf. If a stack isn't mapped in [stacks]
  # and its env file has no VPS_HOST, VPS_HOST resolves empty and the block
  # above never fires, so deploy falls through to the local Docker daemon
  # with no signal at all. When the stack's own services.conf declares a
  # VPS_HOST, that's a strong sign the deploy was meant to reach a VPS —
  # `validate` treats it as an unrecognized-but-harmless key, which reads as
  # "this will deploy there" even though it's never consulted for dispatch.
  if [ "$force_local" != "true" ] && [ -z "${VPS_HOST:-}" ]; then
    local _stack_dir="${CMD_STACK_DIR:-$CLI_ROOT/stacks/$stack}"
    if [ -f "$_stack_dir/services.conf" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?VPS_HOST[[:space:]]*=[[:space:]]*[^[:space:]]' "$_stack_dir/services.conf"; then
      fail "Stack '$stack' has no VPS_HOST resolved (not mapped under [stacks] in strut.conf, and no VPS_HOST in ${env_name:-the env file}), but its services.conf declares VPS_HOST — that file isn't used for dispatch. Deploying now would run against the LOCAL Docker daemon, not the VPS. Add '$stack = <host_alias>' under [stacks] (and the host under [hosts]) in strut.conf, or set VPS_HOST in the stack's env file, to deploy remotely — or pass --force-local to confirm this is intentional."
      # fail() exits in production, but tests stub it to `return 1` so the
      # guard is assertable without killing the runner — keep this explicit
      # return so the guard still stops dispatch under that stub. See #488.
      return 1
    fi
  fi

  if $pull_only; then
    pull_only_stack "$stack" "$env_file" "$services"
    return 0
  fi

  # Guard: detect data-destructive env changes before deploying
  _deploy_volguard "$stack" "$env_file" "$confirm_data_move" || return 1
  diff_warn_env_divergence "$stack" "$env_file" "${CMD_STACK_DIR:-$CLI_ROOT/stacks/$stack}"

  declare -F history_record >/dev/null || source "$LIB/history.sh"
  declare -F rollback_get_latest_snapshot >/dev/null || source "$LIB/rollback.sh"
  local _deploy_stack_dir="${CMD_STACK_DIR:-$CLI_ROOT/stacks/$stack}"
  local _deploy_rc=0

  case "$deploy_mode" in
    blue-green)
      bg_deploy_stack "$stack" "$env_file" "$services" || _deploy_rc=$?
      ;;
    standard|*)
      deploy_stack "$stack" "$env_file" "$services" || _deploy_rc=$?
      ;;
  esac

  # release_id = the rollback snapshot this deploy just (re)saved before
  # restarting containers — i.e. the restore target for reverting PAST this
  # deploy. Empty when no snapshot was saved (first deploy, 0 running
  # containers) — history_show handles that gracefully.
  local _deploy_snapshot _deploy_release_id=""
  _deploy_snapshot=$(rollback_get_latest_snapshot "$stack" "$env_name" 2>/dev/null) || true
  [ -n "$_deploy_snapshot" ] && _deploy_release_id=$(basename "$_deploy_snapshot" .json)

  if [ "$_deploy_rc" -eq 0 ]; then
    history_record "$_deploy_stack_dir" "deploy" "success" "env=${env_name:-}" "mode=$deploy_mode" "git_sha=$(history_git_sha)" "release_id=$_deploy_release_id"
  else
    history_record "$_deploy_stack_dir" "deploy" "failed" "env=${env_name:-}" "mode=$deploy_mode" "git_sha=$(history_git_sha)" "release_id=$_deploy_release_id"
  fi
  return "$_deploy_rc"
}

# cmd_health (no args — reads CMD_*)
cmd_health() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"
  local json_flag="$CMD_JSON"

  # Prefer remote execution for stacks that map to a VPS host, so health
  # checks reflect the actual running state rather than local Docker.
  if [ -f "$env_file" ]; then
    validate_env_file "$env_file"
  fi
  if should_dispatch_remote; then
    local remote_args="health"
    if [ -n "$json_flag" ]; then
      remote_args="$remote_args --json"
    fi
    if [ -n "$services" ]; then
      remote_args="$remote_args --services $services"
    fi
    run_remote_strut "$stack" "$env_name" "$remote_args"
    return $?
  fi

  # Local path: run health checks against the local Docker daemon.
  [ -f "$env_file" ] && safe_load_env "$env_file" 2>/dev/null || true  # env file may not exist for local-only health checks
  local compose_file="$stack_dir/docker-compose.yml"
  # Blue-green stacks run under a <stack>-<env>-<color> project — target
  # the active color, not the plain <stack>-<env> project (strut#384).
  declare -F _bg_active_project >/dev/null || source "$LIB/deploy_blue_green.sh"
  local bg_project
  bg_project="$(_bg_active_project "$stack" "$env_name")"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services" "$bg_project")

  local health_rc=0
  health_run_all "$stack" "$compose_cmd" "$compose_file" "$json_flag" || health_rc=$?

  if [ "$health_rc" -ne 0 ]; then
    # Fire on_health_fail hook (warn-only — never mask the original exit code)
    HEALTH_STATUS="$health_rc" fire_hook_or_warn on_health_fail "$stack_dir"
  fi

  return "$health_rc"
}

# cmd_status (no args — reads CMD_*)
cmd_status() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"
  local json_flag="$CMD_JSON"

  # Prefer remote execution for stacks that map to a VPS host, so status
  # reflects the real remote containers instead of the (empty) local daemon.
  # Check this before validating the env file: a topology-only stack
  # (VPS_HOST/host layer supplied entirely via strut.conf [stacks]/[hosts],
  # no base per-env file on disk) is a valid config for this read-only
  # command and shouldn't hard-fail before we even know we're dispatching
  # remote.
  if should_dispatch_remote; then
    local remote_args="status"
    if [ -n "$json_flag" ]; then
      remote_args="$remote_args --json"
    fi
    if [ -n "$services" ]; then
      remote_args="$remote_args --services $services"
    fi
    run_remote_strut "$stack" "$env_name" "$remote_args"
    return $?
  fi

  # Local path: we're not dispatching remote, so an explicitly-requested but
  # missing env file (e.g. a typo'd --env) must still fail loudly here.
  validate_env_file "$env_file"

  # Local path: query the local Docker daemon and show where we're looking.
  # Blue-green stacks run under a <stack>-<env>-<color> project — target
  # the active color, not the plain <stack>-<env> project (strut#384).
  declare -F _bg_active_project >/dev/null || source "$LIB/deploy_blue_green.sh"
  local bg_project
  bg_project="$(_bg_active_project "$stack" "$env_name")"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services" "$bg_project")
  # Extract the resolved project name for a clear "looking here" message.
  local project_name
  project_name=$(echo "$compose_cmd" | grep -oE '\-\-project\-name [^ ]+' | awk '{print $2}') || true
  log "Querying local Docker daemon — host: local, project: ${project_name:-<unknown>}"
  # shellcheck disable=SC2086
  $compose_cmd ps

  # Timers section — only when the stack declares scheduled jobs.
  declare -F timers_conf_path >/dev/null || source "$LIB/timers.sh"
  local _timers_conf
  _timers_conf="$(timers_conf_path "$stack_dir")"
  if [ -f "$_timers_conf" ]; then
    echo ""
    echo -e "${BLUE}Timers:${NC}"
    timers_list "$stack" "$stack_dir"
  fi
}

# cmd_prune [--volumes] [--all] [--no-protect]
#
# Forwards flags through to docker_prune, automatically scoping the prune to
# the current stack so rollback snapshots can protect their referenced images
# from deletion. Opt out with --no-protect or PRUNE_PROTECT_ROLLBACK_IMAGES=false.
cmd_prune() {
  local -a args=()
  local protect=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-protect) protect=false; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  # Default to --volumes when caller passed no flags (preserves prior behavior).
  [ "${#args[@]}" -eq 0 ] && args=(--volumes)

  if [ "$protect" = "true" ] && [ -n "${CMD_STACK:-}" ]; then
    args+=(--stack "$CMD_STACK")
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for prune:${NC}"
    run_cmd "Docker system prune" docker system prune -af "${args[@]}"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi
  docker_prune "${args[@]}"
}
