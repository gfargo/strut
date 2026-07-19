#!/usr/bin/env bash
# ==================================================
# lib/timers.sh — Declarative stack-level systemd timers
# ==================================================
# Requires: lib/utils.sh, lib/output.sh sourced first
#
# Parses stacks/<stack>/timers.conf (an INI file: one [section] per job)
# and renders/installs matching systemd .service/.timer unit pairs on the
# host it runs on. Every managed unit is namespaced "strut-<stack>-<name>"
# so install/remove/drift never touch operator-owned units.
#
# timers.conf format:
#   [port-sync]
#   exec = ./port-sync.sh
#   on_calendar = *:*:0/60          # systemd OnCalendar syntax
#   env_file = /etc/default/media-port-sync
#
#   [nightly-backup]
#   exec = strut media backup
#   interval = 1d                   # alternative to on_calendar: <N>s|m|h|d
#
# Optional per-section keys: description, user.
#
# Provides:
#   timers_conf_path <stack_dir>
#   timers_parse <stack_dir>
#   timers_expand_interval <value>
#   timers_unit_basename <stack> <name>
#   timers_render_service <stack> <name> <exec> <env_file> <description> <user>
#   timers_render_timer <name> <schedule_type> <schedule_value> [description]
#   timers_install <stack> <stack_dir>
#   timers_remove <stack> <stack_dir>
#   timers_list <stack> <stack_dir>
#   timers_drift <stack> <stack_dir>

set -euo pipefail

# Guard on a function, not a color var (RED is legitimately "" on a
# non-tty) — re-sourcing utils.sh here would clobber any caller-installed
# stub of a utils.sh function (e.g. resolve_compose_cmd in tests).
declare -F warn >/dev/null || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"
declare -F out_table_header >/dev/null || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

# ── Config path ───────────────────────────────────────────────────────────────

# timers_conf_path <stack_dir>
timers_conf_path() {
  local stack_dir="$1"
  echo "$stack_dir/timers.conf"
}

# ── Parsing ───────────────────────────────────────────────────────────────────

# timers_expand_interval <value>
#
# Validates a systemd-native duration shorthand (<N>s|m|h|d) and echoes it
# back verbatim — systemd's OnUnitActiveSec/OnBootSec already understand
# this format natively, so "expansion" is really just validation. Returns
# 1 on an unrecognized format.
timers_expand_interval() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+(s|m|h|d)$ ]] || return 1
  echo "$value"
}

# _timers_emit_record <section> <exec> <on_calendar> <interval> <env_file> <description> <user>
#
# Internal: validates one parsed [section] and, if valid, echoes a record
# delimited by the ASCII unit separator (\x1f): name<US>exec<US>schedule_type
# <US>schedule_value<US>env_file<US>description<US>user. \x1f (rather than
# '|') is used because 'exec' is a free-form shell command that may itself
# contain a literal '|' (e.g. "./x.sh | tee log").
# schedule_type is "calendar" (OnCalendar=) or "interval" (OnUnitActiveSec=/OnBootSec=).
# Invalid or incomplete sections are warned about and skipped, never abort
# the whole parse — one bad timer shouldn't break every other timer's install.
_timers_emit_record() {
  local section="$1" exec_cmd="$2" on_calendar="$3" interval="$4"
  local env_file="$5" description="$6" user="$7"

  local schedule_type="" schedule_value=""
  if [ -n "$on_calendar" ] && [ -n "$interval" ]; then
    warn "timers.conf [$section]: both 'on_calendar' and 'interval' set — 'on_calendar' wins, remove one"
  fi

  if [ -n "$on_calendar" ]; then
    schedule_type="calendar"
    schedule_value="$on_calendar"
  elif [ -n "$interval" ]; then
    if ! schedule_value="$(timers_expand_interval "$interval")"; then
      warn "timers.conf [$section]: invalid interval '$interval' (expected <N>s|m|h|d) — skipping"
      return 0
    fi
    schedule_type="interval"
  fi

  if [ -z "$exec_cmd" ]; then
    warn "timers.conf [$section]: missing 'exec' — skipping"
    return 0
  fi
  if [ -z "$schedule_type" ]; then
    warn "timers.conf [$section]: missing 'on_calendar' or 'interval' — skipping"
    return 0
  fi

  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$section" "$exec_cmd" "$schedule_type" "$schedule_value" "$env_file" "$description" "$user"
}

# timers_parse <stack_dir>
#
# INI parser modeled on topology_load (lib/topology.sh): section regex
# ^\[([a-zA-Z0-9_-]+)\]$, key = value regex
# ^[[:space:]]*([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.+)$.
# Echoes one \x1f-delimited record per valid [section] — see
# _timers_emit_record. Safe to call on a stack with no timers.conf (no-op).
timers_parse() {
  local stack_dir="$1"
  local conf
  conf="$(timers_conf_path "$stack_dir")"
  [ -f "$conf" ] || return 0

  local section="" exec_cmd="" on_calendar="" interval="" env_file="" description="" user=""
  local have_section=false
  local line key val

  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
      if $have_section; then
        _timers_emit_record "$section" "$exec_cmd" "$on_calendar" "$interval" "$env_file" "$description" "$user"
      fi
      section="${BASH_REMATCH[1]}"
      exec_cmd=""; on_calendar=""; interval=""; env_file=""; description=""; user=""
      have_section=true
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Trim trailing whitespace
      val="${val%"${val##*[![:space:]]}"}"
      case "$key" in
        exec)        exec_cmd="$val" ;;
        on_calendar) on_calendar="$val" ;;
        interval)    interval="$val" ;;
        env_file)    env_file="$val" ;;
        description) description="$val" ;;
        user)        user="$val" ;;
      esac
    fi
  done < "$conf"

  if $have_section; then
    _timers_emit_record "$section" "$exec_cmd" "$on_calendar" "$interval" "$env_file" "$description" "$user"
  fi
}

# ── Naming ────────────────────────────────────────────────────────────────────

# timers_unit_basename <stack> <name>
#
# Every unit strut installs is namespaced this way so install/remove/drift
# only ever touch strut-managed units, never an operator's hand-installed
# timer that happens to live alongside it.
timers_unit_basename() {
  local stack="$1" name="$2"
  echo "strut-${stack}-${name}"
}

# ── Rendering ─────────────────────────────────────────────────────────────────

# timers_render_service <stack> <name> <exec> <env_file> <description> <user>
#
# Echoes a systemd .service unit. ExecStart is wrapped in `/bin/sh -c` so
# both a relative script path (resolved via WorkingDirectory) and a
# multi-word command (e.g. "strut media backup") work without the caller
# having to pre-resolve an absolute binary path.
timers_render_service() {
  local stack="$1" name="$2" exec_cmd="$3" env_file="$4" description="$5" user="$6"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  local exec_escaped="${exec_cmd//\'/\'\\\'\'}"

  echo "[Unit]"
  echo "Description=${description:-strut timer: $stack/$name}"
  echo ""
  echo "[Service]"
  echo "Type=oneshot"
  [ -n "$user" ] && echo "User=$user"
  echo "WorkingDirectory=$stack_dir"
  [ -n "$env_file" ] && echo "EnvironmentFile=$env_file"
  echo "ExecStart=/bin/sh -c '$exec_escaped'"
  echo ""
  echo "# Managed by strut — do not edit by hand."
  echo "# Edit $stack_dir/timers.conf and re-run 'strut $stack timers install'."
}

# timers_render_timer <name> <schedule_type> <schedule_value> [description]
#
# Echoes a systemd .timer unit. "calendar" schedules become OnCalendar=;
# "interval" schedules become OnBootSec=+OnUnitActiveSec= (systemd already
# accepts <N>s|m|h|d for both, so schedule_value is used verbatim).
timers_render_timer() {
  local name="$1" schedule_type="$2" schedule_value="$3" description="${4:-}"

  echo "[Unit]"
  echo "Description=${description:-strut timer: $name}"
  echo ""
  echo "[Timer]"
  case "$schedule_type" in
    interval)
      echo "OnBootSec=$schedule_value"
      echo "OnUnitActiveSec=$schedule_value"
      ;;
    *)
      echo "OnCalendar=$schedule_value"
      ;;
  esac
  echo "Persistent=true"
  echo ""
  echo "[Install]"
  echo "WantedBy=timers.target"
  echo ""
  echo "# Managed by strut — do not edit by hand."
}

# ── Install / remove ──────────────────────────────────────────────────────────

# _timers_unit_dir — overridable only for tests (production always uses the
# real systemd system unit directory).
_timers_unit_dir() {
  echo "${STRUT_TIMERS_UNIT_DIR:-/etc/systemd/system}"
}

# timers_install <stack> <stack_dir>
#
# Renders + installs every configured timer idempotently: writes a unit
# file only when its rendered content differs from what's on disk, runs a
# single `daemon-reload` if anything changed, then enables --now every
# configured timer (cheap and idempotent even when nothing changed — covers
# a timer an operator manually disabled). No-op (returns 0) when the stack
# has no timers.conf, or when systemctl isn't available (non-systemd host —
# never abort a deploy over this optional feature). Honors DRY_RUN.
timers_install() {
  local stack="$1"
  local stack_dir="$2"
  local conf
  conf="$(timers_conf_path "$stack_dir")"
  [ -f "$conf" ] || return 0

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found — skipping timer install for '$stack' (not a systemd host)"
    return 0
  fi

  local records
  records="$(timers_parse "$stack_dir")"
  [ -n "$records" ] || return 0

  local unit_dir
  unit_dir="$(_timers_unit_dir)"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Execution plan for timers install ($stack):${NC}"
    local name exec_cmd schedule_type schedule_value env_file description user
    while IFS=$'\x1f' read -r name exec_cmd schedule_type schedule_value env_file description user; do
      [ -n "$name" ] || continue
      local unit
      unit="$(timers_unit_basename "$stack" "$name")"
      run_cmd "Render + install $unit.service/.timer" echo "render"
      run_cmd "Enable --now $unit.timer" systemctl enable --now "$unit.timer"
    done <<< "$records"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  local changed=false
  local name exec_cmd schedule_type schedule_value env_file description user
  while IFS=$'\x1f' read -r name exec_cmd schedule_type schedule_value env_file description user; do
    [ -n "$name" ] || continue
    local unit service_file timer_file
    unit="$(timers_unit_basename "$stack" "$name")"
    service_file="$unit_dir/$unit.service"
    timer_file="$unit_dir/$unit.timer"

    local rendered_service rendered_timer
    rendered_service="$(timers_render_service "$stack" "$name" "$exec_cmd" "$env_file" "$description" "$user")"
    rendered_timer="$(timers_render_timer "$name" "$schedule_type" "$schedule_value" "$description")"

    local existing_service="" existing_timer=""
    [ -f "$service_file" ] && existing_service="$(cat "$service_file" 2>/dev/null)"
    [ -f "$timer_file" ] && existing_timer="$(cat "$timer_file" 2>/dev/null)"

    if [ "$existing_service" != "$rendered_service" ]; then
      log "Installing $unit.service"
      printf '%s\n' "$rendered_service" | sudo tee "$service_file" >/dev/null
      changed=true
    fi
    if [ "$existing_timer" != "$rendered_timer" ]; then
      log "Installing $unit.timer"
      printf '%s\n' "$rendered_timer" | sudo tee "$timer_file" >/dev/null
      changed=true
    fi
  done <<< "$records"

  if $changed; then
    log "Reloading systemd daemon"
    sudo systemctl daemon-reload
  fi

  while IFS=$'\x1f' read -r name exec_cmd schedule_type schedule_value env_file description user; do
    [ -n "$name" ] || continue
    local unit
    unit="$(timers_unit_basename "$stack" "$name")"
    sudo systemctl enable --now "$unit.timer" >/dev/null 2>&1 \
      || warn "Failed to enable/start $unit.timer"
  done <<< "$records"

  ok "Timers installed for $stack"
}

# timers_remove <stack> <stack_dir>
#
# Disables and deletes every strut-managed unit for this stack (matched by
# the strut-<stack>-* namespace, regardless of what's currently in
# timers.conf — so a timer removed from config still gets cleaned up).
timers_remove() {
  local stack="$1"
  local stack_dir="${2:-}"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found — nothing to remove"
    return 0
  fi

  local unit_dir
  unit_dir="$(_timers_unit_dir)"
  local prefix
  prefix="$(timers_unit_basename "$stack" "")"

  local found=false
  local f unit
  for f in "$unit_dir/${prefix}"*.timer; do
    [ -e "$f" ] || continue
    found=true
    unit="$(basename "$f" .timer)"

    if [ "${DRY_RUN:-false}" = "true" ]; then
      run_cmd "Disable + remove $unit" systemctl disable --now "$unit.timer"
      continue
    fi

    log "Removing $unit"
    sudo systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
    sudo rm -f "$unit_dir/$unit.timer" "$unit_dir/$unit.service"
  done

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  if $found; then
    sudo systemctl daemon-reload
    ok "Removed strut-managed timers for $stack"
  else
    log "No strut-managed timers found for $stack"
  fi
}

# ── Listing ───────────────────────────────────────────────────────────────────

# _timers_lookup_next_last <unit> <list_timers_output>
#
# Echoes "next|last" for <unit>.timer parsed from `systemctl list-timers
# --all --no-legend` output. Columns are separated by runs of 2+ spaces
# (systemctl pads for alignment); a unit missing from the output (never
# started, or systemctl unavailable) echoes an empty "|" pair.
_timers_lookup_next_last() {
  local unit="$1" lt_output="$2"
  local line
  line="$(printf '%s\n' "$lt_output" | grep -F "${unit}.timer" | head -1)" || true
  [ -n "$line" ] || { echo "|"; return 0; }
  local next last
  next="$(printf '%s\n' "$line" | awk -F'  +' '{print $1}')"
  last="$(printf '%s\n' "$line" | awk -F'  +' '{print $3}')"
  echo "${next}|${last}"
}

# timers_list <stack> <stack_dir>
#
# Lists configured timers with next/last run times. Text or JSON per
# output_mode (lib/output.sh). No-op-friendly: a stack with no timers.conf
# prints an empty list rather than erroring.
timers_list() {
  local stack="$1"
  local stack_dir="$2"

  local conf
  conf="$(timers_conf_path "$stack_dir")"

  local records=""
  [ -f "$conf" ] && records="$(timers_parse "$stack_dir")"

  local lt_output=""
  if [ -n "$records" ] && command -v systemctl >/dev/null 2>&1; then
    lt_output="$(systemctl list-timers --all --no-legend "$(timers_unit_basename "$stack" "*").timer" 2>/dev/null)" || lt_output=""
  fi

  if [ "$(output_mode)" = "json" ]; then
    out_json_object
      out_json_array "timers"
      if [ -n "$records" ]; then
        local name exec_cmd schedule_type schedule_value env_file description user
        while IFS=$'\x1f' read -r name exec_cmd schedule_type schedule_value env_file description user; do
          [ -n "$name" ] || continue
          local unit next_last next last
          unit="$(timers_unit_basename "$stack" "$name")"
          next_last="$(_timers_lookup_next_last "$unit" "$lt_output")"
          next="${next_last%%|*}"
          last="${next_last##*|}"
          out_json_object
            out_json_field "name" "$name"
            out_json_field "unit" "$unit"
            out_json_field "exec" "$exec_cmd"
            out_json_field "schedule_type" "$schedule_type"
            out_json_field "schedule" "$schedule_value"
            out_json_field "next" "$next"
            out_json_field "last" "$last"
          out_json_close_object
        done <<< "$records"
      fi
      out_json_close_array
    out_json_close_object
    out_json_newline
    return 0
  fi

  if [ -z "$records" ]; then
    out_table_empty "(no timers configured)"
    return 0
  fi

  out_table_header "Name" "Schedule" "Next" "Last"
  local name exec_cmd schedule_type schedule_value env_file description user
  while IFS=$'\x1f' read -r name exec_cmd schedule_type schedule_value env_file description user; do
    [ -n "$name" ] || continue
    local unit next_last next last
    unit="$(timers_unit_basename "$stack" "$name")"
    next_last="$(_timers_lookup_next_last "$unit" "$lt_output")"
    next="${next_last%%|*}"
    last="${next_last##*|}"
    out_table_row "$name" "$schedule_value" "${next:--}" "${last:--}"
  done <<< "$records"
  out_table_render
}

# ── Drift ─────────────────────────────────────────────────────────────────────

# timers_drift <stack> <stack_dir>
#
# Compares each configured timer's rendered unit content against what's
# actually installed on this host — the same content check timers_install
# uses to decide whether a unit needs rewriting — plus flags strut-managed
# units on disk with no matching timers.conf section (e.g. a section
# renamed or deleted without running 'timers remove'). Echoes one
# \x1f-delimited "unit\x1freason" record per drifted unit, reason being
# "missing" (configured but not installed), "modified" (installed content
# differs from what timers.conf would render — hand-edited or stale), or
# "orphaned" (installed but no matching config section).
#
# No-op (no output, status 0) when the stack has no timers.conf or
# systemctl isn't available: like timers_install/timers_list, this only
# makes sense run on the actual host the timers are installed on — it does
# not fetch anything over SSH.
timers_drift() {
  local stack="$1"
  local stack_dir="$2"
  local conf
  conf="$(timers_conf_path "$stack_dir")"
  [ -f "$conf" ] || return 0

  command -v systemctl >/dev/null 2>&1 || return 0

  local records
  records="$(timers_parse "$stack_dir")"
  [ -n "$records" ] || return 0

  local unit_dir
  unit_dir="$(_timers_unit_dir)"

  local -A configured_units=()
  local name exec_cmd schedule_type schedule_value env_file description user
  while IFS=$'\x1f' read -r name exec_cmd schedule_type schedule_value env_file description user; do
    [ -n "$name" ] || continue
    local unit service_file timer_file
    unit="$(timers_unit_basename "$stack" "$name")"
    configured_units["$unit"]=1
    service_file="$unit_dir/$unit.service"
    timer_file="$unit_dir/$unit.timer"

    if [ ! -f "$service_file" ] && [ ! -f "$timer_file" ]; then
      printf '%s\x1f%s\n' "$unit" "missing"
      continue
    fi

    local rendered_service rendered_timer existing_service existing_timer
    rendered_service="$(timers_render_service "$stack" "$name" "$exec_cmd" "$env_file" "$description" "$user")"
    rendered_timer="$(timers_render_timer "$name" "$schedule_type" "$schedule_value" "$description")"
    existing_service=""; existing_timer=""
    [ -f "$service_file" ] && existing_service="$(cat "$service_file" 2>/dev/null)"
    [ -f "$timer_file" ] && existing_timer="$(cat "$timer_file" 2>/dev/null)"

    if [ "$existing_service" != "$rendered_service" ] || [ "$existing_timer" != "$rendered_timer" ]; then
      printf '%s\x1f%s\n' "$unit" "modified"
    fi
  done <<< "$records"

  local prefix
  prefix="$(timers_unit_basename "$stack" "")"
  local f ubase
  for f in "$unit_dir/${prefix}"*.timer; do
    [ -e "$f" ] || continue
    ubase="$(basename "$f" .timer)"
    [ -n "${configured_units[$ubase]:-}" ] && continue
    printf '%s\x1f%s\n' "$ubase" "orphaned"
  done
}
