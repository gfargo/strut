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

# _status_health <stack> <env_name> — emits one of: healthy | degraded | down | unknown
#
# Fast check — runs `docker compose ps` and aggregates container State.
# Dispatches to the VPS over SSH for stacks whose env file sets VPS_HOST
# (see _status_health_remote). Returns "unknown" if compose isn't available
# or the stack has no docker-compose.yml.
_status_health() {
  local stack="$1"
  local env_name="${2:-}"
  local stack_dir="$CLI_ROOT/stacks/$stack"

  [ -f "$stack_dir/docker-compose.yml" ] || { echo "unknown"; return; }

  local env_file
  if [ -n "$env_name" ]; then
    env_file="$CLI_ROOT/.$env_name.env"
  else
    env_file="$CLI_ROOT/.env"
  fi

  # Each stack's env file is optional and independent — clear connection vars
  # from the previous loop iteration so a stack with no VPS_HOST doesn't
  # inherit the prior stack's remote target.
  unset VPS_HOST VPS_USER VPS_PORT VPS_SSH_KEY VPS_DEPLOY_DIR 2>/dev/null || true
  [ -f "$env_file" ] && { set -a; source "$env_file"; set +a; } 2>/dev/null || true

  if should_dispatch_remote; then
    _status_health_remote "$stack" "$env_name"
    return
  fi

  command -v docker >/dev/null 2>&1 || { echo "unknown"; return; }

  local compose_cmd
  if ! compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "" 2>/dev/null); then
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
      echo '{"timestamp":"'"$(date -u +%FT%TZ)"'","stacks":[],"summary":{"total":0,"healthy":0,"degraded":0,"down":0}}'
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

  for name in "${stacks[@]}"; do
    total=$((total + 1))
    local health deploy_ts backup_ts
    health=$(_status_health "$name" "$env_name")
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
    out_table_header "Stack" "Health" "Last Deploy" "Backup Age"
    local i
    for i in "${!rows_stack[@]}"; do
      out_table_row \
        "${rows_stack[$i]}" \
        "$(_status_health_glyph "${rows_health[$i]}")" \
        "${rows_deploy[$i]}" \
        "${rows_backup[$i]}"
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
