#!/usr/bin/env bash
# ==================================================
# lib/cmd_status_all.sh — Multi-stack dashboard
# ==================================================
# `strut status-all [--env <name>] [--json]`
# Shows a one-screen overview of every stack: health, last deploy, backup
# age. Designed to be fast — reads file mtimes and minimal docker output
# (or dispatches over SSH for VPS-deployed stacks), not full HTTP health
# probes.

set -euo pipefail

# ── Time helpers ──────────────────────────────────────────────────────────────

# _status_mtime <path> — emit unix epoch mtime, or empty if missing
_status_mtime() {
  local p="$1"
  [ -e "$p" ] || return 0
  # GNU first (Linux CI), BSD fallback (macOS). BSD order fails on Linux
  # because GNU `stat -f` means filesystem mode — it succeeds with wrong output.
  stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || true
}

# _status_humanize_age <seconds> — "4h ago", "2d ago", etc.
_status_humanize_age() {
  local secs="$1"
  [ -z "$secs" ] && { echo "-"; return; }
  if [ "$secs" -lt 60 ]; then
    echo "${secs}s ago"
  elif [ "$secs" -lt 3600 ]; then
    echo "$((secs / 60))m ago"
  elif [ "$secs" -lt 86400 ]; then
    echo "$((secs / 3600))h ago"
  else
    echo "$((secs / 86400))d ago"
  fi
}

# _status_newest_mtime <dir> <glob> — newest mtime of files matching the glob
_status_newest_mtime() {
  local dir="$1"
  local pattern="$2"
  [ -d "$dir" ] || return 0
  local f newest="" newest_ts=""
  for f in "$dir"/$pattern; do
    [ -e "$f" ] || continue
    local ts
    ts=$(_status_mtime "$f")
    [ -z "$ts" ] && continue
    if [ -z "$newest_ts" ] || [ "$ts" -gt "$newest_ts" ]; then
      newest_ts="$ts"
      newest="$f"
    fi
  done
  echo "$newest_ts"
}

# ── Per-stack collectors ──────────────────────────────────────────────────────

# _status_last_deploy <stack> — epoch of newest rollback snapshot, or empty
_status_last_deploy() {
  local stack="$1"
  _status_newest_mtime "$CLI_ROOT/stacks/$stack/.rollback" "*.json"
}

# _status_backup_age <stack> — epoch of newest backup file, or empty
_status_backup_age() {
  local stack="$1"
  local stack_dir="$CLI_ROOT/stacks/$stack"
  local dir="${BACKUP_LOCAL_DIR:-$stack_dir/backups}"
  _status_newest_mtime "$dir" "*"
}

# _status_resolve_env_file <stack> <env_name>
# Uses the entrypoint's stack-aware resolver when available. The fallback keeps
# this module standalone for tests and direct library consumers.
_status_resolve_env_file() {
  local stack="$1"
  local env_name="${2:-}"
  local stack_dir="$CLI_ROOT/stacks/$stack"

  if declare -F resolve_env_file >/dev/null 2>&1; then
    resolve_env_file "$stack" "$env_name"
    return
  fi

  if [ -n "$env_name" ]; then
    if [ -f "$stack_dir/.$env_name.enc.env" ]; then
      echo "$stack_dir/.$env_name.enc.env"
    elif [ -f "$stack_dir/.$env_name.env" ]; then
      echo "$stack_dir/.$env_name.env"
    elif [ -f "$CLI_ROOT/.$env_name.enc.env" ]; then
      echo "$CLI_ROOT/.$env_name.enc.env"
    else
      echo "$CLI_ROOT/.$env_name.env"
    fi
  elif [ -f "$stack_dir/.env" ]; then
    echo "$stack_dir/.env"
  else
    echo "$CLI_ROOT/.env"
  fi
}

# _status_prepare_stack_context <stack> <env_name>
# Resolves health intent exactly like normal stack dispatch: stack-aware base
# env first, then topology defaults and the tracked host layer. Callers should
# run this in a subshell per stack so arbitrary env-layer values cannot leak to
# the next row.
_status_prepare_stack_context() {
  local stack="$1"
  local env_name="${2:-}"
  local stack_dir="$CLI_ROOT/stacks/$stack"

  unset VPS_HOST VPS_USER VPS_PORT VPS_SSH_KEY VPS_DEPLOY_DIR _TOPO_ACTIVE_HOST_ALIAS 2>/dev/null || true

  _STATUS_ENV_FILE=$(_status_resolve_env_file "$stack" "$env_name")
  [ -f "$_STATUS_ENV_FILE" ] && safe_load_env "$_STATUS_ENV_FILE" 2>/dev/null || true

  if declare -F topology_apply_to_env >/dev/null 2>&1; then
    topology_apply_to_env "$stack" "$stack_dir"
  fi

  _STATUS_TARGET_SCOPE="local"
  if should_dispatch_remote; then
    _STATUS_TARGET_SCOPE="remote"
  fi
  _STATUS_TARGET_ALIAS="${_TOPO_ACTIVE_HOST_ALIAS:-}"
  _STATUS_TARGET_HOST="${VPS_HOST:-}"
  if [ -n "$env_name" ]; then
    _STATUS_HEALTH_ENV="$env_name"
  elif [ "$_STATUS_TARGET_SCOPE" = "remote" ]; then
    # run_remote_strut preserves the historical no-flag remote default.
    _STATUS_HEALTH_ENV="prod"
  else
    _STATUS_HEALTH_ENV="default"
  fi
}

# _status_health_resolved <stack> <env_name>
# Probes health after _status_prepare_stack_context has resolved the target.
_status_health_resolved() {
  local stack="$1"
  local env_name="${2:-}"
  local stack_dir="$CLI_ROOT/stacks/$stack"

  [ -f "$stack_dir/docker-compose.yml" ] || { echo "unknown"; return; }

  if [ "$_STATUS_TARGET_SCOPE" = "remote" ]; then
    _status_health_remote "$stack" "$env_name"
    return
  fi

  command -v docker >/dev/null 2>&1 || { echo "unknown"; return; }

  local compose_cmd
  if ! compose_cmd=$(resolve_compose_cmd "$stack" "$_STATUS_ENV_FILE" "" 2>/dev/null); then
    echo "unknown"
    return
  fi

  local ps_output
  if ! ps_output=$($compose_cmd ps --format '{{.State}}' 2>/dev/null); then
    echo "unknown"
    return
  fi

  [ -z "$ps_output" ] && { echo "down"; return; }

  local total=0 running=0 other=0
  while IFS= read -r state; do
    [ -z "$state" ] && continue
    total=$((total + 1))
    case "$state" in
      running) running=$((running + 1)) ;;
      *)       other=$((other + 1)) ;;
    esac
  done <<<"$ps_output"

  if [ "$total" -eq 0 ]; then
    echo "down"
  elif [ "$running" -eq "$total" ]; then
    echo "healthy"
  elif [ "$running" -eq 0 ]; then
    echo "down"
  else
    echo "degraded"
  fi
}

# _status_health <stack> <env_name> — compatibility wrapper used by tests and
# direct callers. Main aggregation uses _status_health_context so target
# provenance is returned with the result.
_status_health() {
  local stack="$1"
  local env_name="${2:-}"
  _status_prepare_stack_context "$stack" "$env_name"
  _status_health_resolved "$stack" "$env_name"
}

# _status_health_context <stack> <env_name>
# Emits unit-separator fields: health, scope, alias, host, effective env.
_status_health_context() {
  local stack="$1"
  local env_name="${2:-}"
  local health
  _status_prepare_stack_context "$stack" "$env_name"
  # Call the public wrapper so existing integrations that override
  # _status_health keep working; command substitution isolates its context.
  health=$(_status_health "$stack" "$env_name")
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$health" "$_STATUS_TARGET_SCOPE" "$_STATUS_TARGET_ALIAS" \
    "$_STATUS_TARGET_HOST" "$_STATUS_HEALTH_ENV"
}

# _status_health_remote <stack> <env_name> — health for a VPS-deployed stack
#
# Dispatches `health --json` over SSH via run_remote_strut and aggregates the
# per-container check results. Only the "Containers"/"Compose File"/
# "Container: <name>" checks are considered — matching the local path's
# container-only semantics rather than cmd_health's broader host-health scope.
_status_health_remote() {
  local stack="$1"
  local env_name="$2"

  command -v ssh >/dev/null 2>&1 || { echo "unknown"; return; }

  local json
  json=$(run_remote_strut "$stack" "$env_name" "health --json" 2>/dev/null) || { echo "unknown"; return; }
  [ -z "$json" ] && { echo "unknown"; return; }

  local hard_fail
  hard_fail=$(echo "$json" | jq -r '[.checks[]? | select(.name=="Containers" or .name=="Compose File") | select(.status=="fail")] | length' 2>/dev/null) || { echo "unknown"; return; }
  [ "${hard_fail:-0}" -gt 0 ] && { echo "down"; return; }

  local total running
  total=$(echo "$json" | jq -r '[.checks[]? | select(.name | startswith("Container:"))] | length' 2>/dev/null) || { echo "unknown"; return; }
  running=$(echo "$json" | jq -r '[.checks[]? | select(.name | startswith("Container:")) | select(.status=="pass" or .status=="warn")] | length' 2>/dev/null) || { echo "unknown"; return; }

  if [ "${total:-0}" -eq 0 ]; then
    echo "down"
  elif [ "$running" -eq "$total" ]; then
    echo "healthy"
  elif [ "$running" -eq 0 ]; then
    echo "down"
  else
    echo "degraded"
  fi
}

# _status_health_glyph <health> — colored symbol for text mode
_status_health_glyph() {
  local health="$1"
  case "$health" in
    healthy)  echo -e "${GREEN}✓${NC} healthy" ;;
    degraded) echo -e "${YELLOW}⚠${NC} degraded" ;;
    down)     echo -e "${RED}✗${NC} down" ;;
    *)        echo "? unknown" ;;
  esac
}

_status_target_label() {
  local scope="$1"
  local alias="${2:-}"
  local host="${3:-}"

  if [ "$scope" != "remote" ]; then
    echo "local"
  elif [ -n "$alias" ] && [ -n "$host" ]; then
    echo "$alias ($host)"
  elif [ -n "$alias" ]; then
    echo "$alias"
  else
    echo "${host:-remote}"
  fi
}

_status_evidence_age() {
  local age="$1"
  local source="$2"
  if [ "$age" = "-" ]; then
    echo "-"
  else
    echo "$age [$source]"
  fi
}

# ── Dashboard command ────────────────────────────────────────────────────────

# cmd_status_all [--env <name>] [--json]
cmd_status_all() {
  local env_name=""
  local json_mode="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env=*)     env_name="${1#*=}"; shift ;;
      --env)       env_name="${2:-}"; shift 2 ;;
      --json)      json_mode="true"; shift ;;
      --help|-h)
        cat <<'EOF'
Usage: strut status-all [--env <name>] [--json]

Dashboard showing health, last deploy, and backup age across every stack.

Flags:
  --env <name>     Filter to a specific environment (default: unscoped)
  --json           Output structured JSON for CI/dashboards
EOF
        return 0
        ;;
      *) fail "Unknown flag: $1"; return 1 ;;
    esac
  done

  if [ ! -d "$CLI_ROOT/stacks" ]; then
    fail "No stacks/ directory found — run 'strut init' to get started"
    return 1
  fi

  local -a stacks=()
  local stack_dir name
  for stack_dir in "$CLI_ROOT/stacks"/*/; do
    [ -d "$stack_dir" ] || continue
    name=$(basename "$stack_dir")
    [ "$name" = "shared" ] && continue
    stacks+=("$name")
  done

  [ "${#stacks[@]}" -eq 0 ] && {
    if [ "$json_mode" = "true" ]; then
      echo '{"timestamp":"'"$(date -u +%FT%TZ)"'","stacks":[],"summary":{"total":0,"healthy":0,"degraded":0,"down":0,"unknown":0}}'
      return 0
    fi
    warn "No stacks found — run 'strut scaffold <name>' to create one"
    return 0
  }

  # Collect status for each stack
  local now
  now=$(date +%s)

  local total=0 healthy=0 degraded=0 down=0 unknown=0
  local -a rows_stack rows_health rows_deploy rows_backup
  local -a rows_target_scope rows_target_alias rows_target_host rows_health_env

  for name in "${stacks[@]}"; do
    total=$((total + 1))
    local health_context health target_scope target_alias target_host health_env
    local deploy_ts backup_ts
    health_context=$(_status_health_context "$name" "$env_name")
    IFS=$'\x1f' read -r health target_scope target_alias target_host health_env <<< "$health_context"
    deploy_ts=$(_status_last_deploy "$name")
    backup_ts=$(_status_backup_age "$name")

    case "$health" in
      healthy)  healthy=$((healthy + 1)) ;;
      degraded) degraded=$((degraded + 1)) ;;
      down)     down=$((down + 1)) ;;
      *)        unknown=$((unknown + 1)) ;;
    esac

    local deploy_age="-" backup_age="-"
    [ -n "$deploy_ts" ] && deploy_age=$(_status_humanize_age $((now - deploy_ts)))
    [ -n "$backup_ts" ] && backup_age=$(_status_humanize_age $((now - backup_ts)))

    rows_stack+=("$name")
    rows_health+=("$health")
    rows_deploy+=("$deploy_age")
    rows_backup+=("$backup_age")
    rows_target_scope+=("$target_scope")
    rows_target_alias+=("$target_alias")
    rows_target_host+=("$target_host")
    rows_health_env+=("$health_env")
  done

  if [ "$json_mode" = "true" ]; then
    OUTPUT_MODE=json
    out_json_object
      out_json_field "timestamp" "$(date -u +%FT%TZ)"
      [ -n "$env_name" ] && out_json_field "env" "$env_name"
      out_json_array "stacks"
        local i
        for i in "${!rows_stack[@]}"; do
          out_json_object
            out_json_field "name" "${rows_stack[$i]}"
            out_json_field "health" "${rows_health[$i]}"
            out_json_field "last_deploy" "${rows_deploy[$i]}"
            out_json_field "backup_age" "${rows_backup[$i]}"
            out_json_field "target_scope" "${rows_target_scope[$i]}"
            out_json_field "target_host_alias" "${rows_target_alias[$i]}"
            out_json_field "target_host" "${rows_target_host[$i]}"
            out_json_field "health_source" "${rows_target_scope[$i]}"
            out_json_field "health_env" "${rows_health_env[$i]}"
            out_json_field "last_deploy_source" "local_rollback"
            out_json_field "backup_source" "local_backup"
          out_json_close_object
        done
      out_json_close_array
      out_json_field_raw "summary" "{\"total\":$total,\"healthy\":$healthy,\"degraded\":$degraded,\"down\":$down,\"unknown\":$unknown}"
    out_json_close_object
    out_json_newline
  else
    echo ""
    local title="strut Dashboard"
    [ -n "$env_name" ] && title="$title ($env_name)"
    echo -e "${BLUE}${title}${NC}"
    echo ""
    out_table_header "Stack" "Target" "Health" "Last Deploy" "Backup Age"
    local i
    for i in "${!rows_stack[@]}"; do
      out_table_row \
        "${rows_stack[$i]}" \
        "$(_status_target_label "${rows_target_scope[$i]}" "${rows_target_alias[$i]}" "${rows_target_host[$i]}")" \
        "$(_status_health_glyph "${rows_health[$i]}")" \
        "$(_status_evidence_age "${rows_deploy[$i]}" "local rollback")" \
        "$(_status_evidence_age "${rows_backup[$i]}" "local backup")"
    done
    out_table_render
    echo ""
    echo "$healthy healthy, $degraded degraded, $down down$([ "$unknown" -gt 0 ] && echo ", $unknown unknown")"
    echo ""
  fi

  # Exit code: 0 if no down/degraded, 1 otherwise
  if [ "$down" -gt 0 ] || [ "$degraded" -gt 0 ]; then
    return 1
  fi
  return 0
}
