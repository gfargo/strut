#!/usr/bin/env bats
# ==================================================
# tests/test_timers.bats — Tests for lib/timers.sh + lib/cmd_timers.sh
# ==================================================
# Run: bats tests/test_timers.bats
# Covers: timers_parse, timers_expand_interval, timers_render_service/timer,
#         timers_install (idempotency, no-config, DRY_RUN), timers_remove,
#         timers_list, cmd_timers dispatch (usage, remote SSH, local).

# Record delimiter used by timers_parse/_timers_emit_record (ASCII unit
# separator — 'exec' is a free-form shell command that may itself contain
# a literal '|', so records can't be pipe-delimited).
US=$'\x1f'

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/timers.sh"

  export LIB="$CLI_ROOT/lib"
  export CLI_ROOT="$TEST_TMP"
  export DRY_RUN=false

  STACK_DIR="$TEST_TMP/stacks/demo"
  mkdir -p "$STACK_DIR"
}

teardown() { common_teardown; }

_write_timers_conf() {
  cat > "$STACK_DIR/timers.conf" <<'EOF'
# comment line, should be ignored

[port-sync]
exec = ./port-sync.sh
interval = 60s
env_file = /etc/default/demo-port-sync
description = Sync port

this is a malformed line, ignored

[nightly-backup]
exec = strut demo backup
on_calendar = daily 03:00
EOF
}

# ── timers_conf_path ──────────────────────────────────────────────────────────

@test "timers_conf_path: echoes <stack_dir>/timers.conf" {
  result=$(timers_conf_path "$STACK_DIR")
  [ "$result" = "$STACK_DIR/timers.conf" ]
}

# ── timers_expand_interval ────────────────────────────────────────────────────

@test "timers_expand_interval: accepts seconds/minutes/hours/days" {
  for v in 60s 5m 1h 1d; do
    run timers_expand_interval "$v"
    [ "$status" -eq 0 ]
    [ "$output" = "$v" ]
  done
}

@test "timers_expand_interval: rejects unrecognized format" {
  run timers_expand_interval "5 minutes"
  [ "$status" -ne 0 ]
}

@test "timers_expand_interval: rejects empty string" {
  run timers_expand_interval ""
  [ "$status" -ne 0 ]
}

# ── timers_unit_basename ──────────────────────────────────────────────────────

@test "timers_unit_basename: namespaces as strut-<stack>-<name>" {
  result=$(timers_unit_basename "demo" "port-sync")
  [ "$result" = "strut-demo-port-sync" ]
}

# ── timers_parse ──────────────────────────────────────────────────────────────

@test "timers_parse: no timers.conf returns nothing, no error" {
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "timers_parse: yields one record per section, comments/blank/malformed lines ignored" {
  _write_timers_conf
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | grep -c '^')
  [ "$count" -eq 2 ]
}

@test "timers_parse: interval section expands to schedule_type=interval" {
  _write_timers_conf
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  local line
  line=$(echo "$output" | grep "^port-sync${US}")
  [ "$line" = "port-sync${US}./port-sync.sh${US}interval${US}60s${US}/etc/default/demo-port-sync${US}Sync port${US}" ]
}

@test "timers_parse: on_calendar section expands to schedule_type=calendar" {
  _write_timers_conf
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  local line
  line=$(echo "$output" | grep "^nightly-backup${US}")
  [ "$line" = "nightly-backup${US}strut demo backup${US}calendar${US}daily 03:00${US}${US}${US}" ]
}

@test "timers_parse: missing exec skips the section with a warning" {
  cat > "$STACK_DIR/timers.conf" <<'EOF'
[broken]
on_calendar = daily 03:00
EOF
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing 'exec'"* ]]
  [[ "$output" != "broken${US}"* ]]
}

@test "timers_parse: missing schedule skips the section with a warning" {
  cat > "$STACK_DIR/timers.conf" <<'EOF'
[broken]
exec = ./run.sh
EOF
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing 'on_calendar' or 'interval'"* ]]
  [[ "$output" != "broken${US}"* ]]
}

@test "timers_parse: invalid interval format skips the section" {
  cat > "$STACK_DIR/timers.conf" <<'EOF'
[broken]
exec = ./run.sh
interval = 5 minutes
EOF
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid interval"* ]]
  [[ "$output" != "broken${US}"* ]]
}

@test "timers_parse: both on_calendar and interval set — on_calendar wins" {
  cat > "$STACK_DIR/timers.conf" <<'EOF'
[both]
exec = ./run.sh
interval = 60s
on_calendar = daily 03:00
EOF
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"both${US}./run.sh${US}calendar${US}daily 03:00${US}${US}${US}"* ]]
}

@test "timers_parse: one bad section doesn't block a good one" {
  cat > "$STACK_DIR/timers.conf" <<'EOF'
[broken]
on_calendar = daily 03:00

[good]
exec = ./run.sh
interval = 1h
EOF
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  local records
  records=$(echo "$output" | grep -E "^[a-zA-Z0-9_-]+${US}")
  local count
  count=$(echo "$records" | grep -c '^')
  [ "$count" -eq 1 ]
  [[ "$records" == "good${US}"* ]]
}

@test "timers_parse: exec containing a literal '|' survives intact (delimiter is \\x1f, not '|')" {
  cat > "$STACK_DIR/timers.conf" <<'EOF'
[piped]
exec = ./x.sh | tee log
interval = 1h
EOF
  run timers_parse "$STACK_DIR"
  [ "$status" -eq 0 ]
  local name exec_cmd schedule_type schedule_value env_file description user
  IFS="$US" read -r name exec_cmd schedule_type schedule_value env_file description user <<< "$output"
  [ "$name" = "piped" ]
  [ "$exec_cmd" = "./x.sh | tee log" ]
  [ "$schedule_type" = "interval" ]
}

# ── timers_render_service / timers_render_timer ───────────────────────────────

@test "timers_render_service: contains exec, WorkingDirectory, EnvironmentFile — only config-derived values" {
  run timers_render_service "acme" "port-sync" "./port-sync.sh" "/etc/default/acme-port-sync" "Sync port" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ExecStart=/bin/sh -c './port-sync.sh'"* ]]
  [[ "$output" == *"WorkingDirectory=$TEST_TMP/stacks/acme"* ]]
  [[ "$output" == *"EnvironmentFile=/etc/default/acme-port-sync"* ]]
  [[ "$output" == *"Description=Sync port"* ]]
  # No hardcoded stack/service name leaks — only what was passed in
  [[ "$output" != *"media"* ]]
  [[ "$output" != *"immich"* ]]
}

@test "timers_render_service: omits EnvironmentFile/User when unset" {
  run timers_render_service "acme" "nightly" "strut acme backup" "" "" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"EnvironmentFile"* ]]
  [[ "$output" != *"User="* ]]
}

@test "timers_render_service: sets User when configured" {
  run timers_render_service "acme" "nightly" "strut acme backup" "" "" "deploy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"User=deploy"* ]]
}

@test "timers_render_service: uses the passed stack_dir instead of recomputing from CLI_ROOT" {
  run timers_render_service "acme" "port-sync" "./port-sync.sh" "" "" "" "/srv/custom-deploy-dir/acme"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WorkingDirectory=/srv/custom-deploy-dir/acme"* ]]
  [[ "$output" != *"$TEST_TMP"* ]]
}

@test "timers_render_timer: calendar schedule emits OnCalendar" {
  run timers_render_timer "nightly" "calendar" "daily 03:00" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"OnCalendar=daily 03:00"* ]]
  [[ "$output" != *"OnUnitActiveSec"* ]]
}

@test "timers_render_timer: interval schedule emits OnBootSec + OnUnitActiveSec" {
  run timers_render_timer "port-sync" "interval" "60s" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"OnBootSec=60s"* ]]
  [[ "$output" == *"OnUnitActiveSec=60s"* ]]
  [[ "$output" != *"OnCalendar"* ]]
}

# ── timers_install ─────────────────────────────────────────────────────────────

_fake_systemd_setup() {
  export STRUT_TIMERS_UNIT_DIR="$TEST_TMP/systemd-units"
  mkdir -p "$STRUT_TIMERS_UNIT_DIR"
  SYSTEMCTL_LOG="$TEST_TMP/systemctl_calls.log"
  : > "$SYSTEMCTL_LOG"
  export SYSTEMCTL_LOG
  sudo() { "$@"; }
  export -f sudo
  systemctl() {
    echo "$*" >> "$SYSTEMCTL_LOG"
    case "$1" in
      list-timers) cat "${FAKE_LIST_TIMERS_OUTPUT:-/dev/null}" 2>/dev/null ;;
      *) return 0 ;;
    esac
  }
  export -f systemctl
}

@test "timers_install: no timers.conf is a silent no-op" {
  _fake_systemd_setup
  run timers_install "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "timers_install: skips gracefully when systemctl is unavailable" {
  _write_timers_conf
  # Shadow `command -v systemctl` to simulate a non-systemd host without
  # touching PATH (which utils.sh itself may still need).
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "systemctl" ]; then
      return 1
    fi
    builtin command "$@"
  }
  export -f command

  run timers_install "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemctl not found"* ]]
}

@test "timers_install: writes rendered units and enables them" {
  _write_timers_conf
  _fake_systemd_setup

  run timers_install "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -f "$STRUT_TIMERS_UNIT_DIR/strut-demo-port-sync.service" ]
  [ -f "$STRUT_TIMERS_UNIT_DIR/strut-demo-port-sync.timer" ]
  [ -f "$STRUT_TIMERS_UNIT_DIR/strut-demo-nightly-backup.service" ]
  [ -f "$STRUT_TIMERS_UNIT_DIR/strut-demo-nightly-backup.timer" ]
  grep -q "daemon-reload" "$SYSTEMCTL_LOG"
  grep -q "enable --now strut-demo-port-sync.timer" "$SYSTEMCTL_LOG"
  grep -q "enable --now strut-demo-nightly-backup.timer" "$SYSTEMCTL_LOG"
}

@test "timers_install: idempotent — unchanged config issues no daemon-reload on reinstall" {
  _write_timers_conf
  _fake_systemd_setup

  timers_install "demo" "$STACK_DIR" >/dev/null
  : > "$SYSTEMCTL_LOG"

  run timers_install "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  ! grep -q "daemon-reload" "$SYSTEMCTL_LOG"
  # Still (idempotently) enables the timers even with no content change
  grep -q "enable --now strut-demo-port-sync.timer" "$SYSTEMCTL_LOG"
}

@test "timers_install: DRY_RUN writes nothing and prints a plan" {
  _write_timers_conf
  _fake_systemd_setup
  export DRY_RUN=true

  run timers_install "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ ! -f "$STRUT_TIMERS_UNIT_DIR/strut-demo-port-sync.service" ]
  [ ! -s "$SYSTEMCTL_LOG" ]
}

# ── timers_remove ──────────────────────────────────────────────────────────────

@test "timers_remove: disables and deletes strut-managed units, leaves others alone" {
  _fake_systemd_setup
  local unit_dir="$STRUT_TIMERS_UNIT_DIR"
  : > "$unit_dir/strut-demo-port-sync.timer"
  : > "$unit_dir/strut-demo-port-sync.service"
  : > "$unit_dir/strut-demo-nightly-backup.timer"
  : > "$unit_dir/strut-demo-nightly-backup.service"
  : > "$unit_dir/operator-owned.timer"

  run timers_remove "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$unit_dir/strut-demo-port-sync.timer" ]
  [ ! -f "$unit_dir/strut-demo-nightly-backup.timer" ]
  [ -f "$unit_dir/operator-owned.timer" ]
  grep -q "disable --now strut-demo-port-sync.timer" "$SYSTEMCTL_LOG"
  grep -q "disable --now strut-demo-nightly-backup.timer" "$SYSTEMCTL_LOG"
  grep -q "daemon-reload" "$SYSTEMCTL_LOG"
}

@test "timers_remove: no managed units found is a clean no-op" {
  _fake_systemd_setup
  run timers_remove "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  ! grep -q "daemon-reload" "$SYSTEMCTL_LOG"
}

# ── timers_drift ──────────────────────────────────────────────────────────────

@test "timers_drift: matching installed units yield no drift" {
  _write_timers_conf
  _fake_systemd_setup
  timers_install "demo" "$STACK_DIR" >/dev/null

  run timers_drift "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "timers_drift: hand-edited unit on disk is flagged" {
  _write_timers_conf
  _fake_systemd_setup
  timers_install "demo" "$STACK_DIR" >/dev/null

  echo "# hand-edited" >> "$STRUT_TIMERS_UNIT_DIR/strut-demo-port-sync.timer"

  run timers_drift "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strut-demo-port-sync${US}modified"* ]]
  [[ "$output" != *"strut-demo-nightly-backup${US}"* ]]
}

@test "timers_drift: configured but never-installed timer is flagged missing" {
  _write_timers_conf
  _fake_systemd_setup

  run timers_drift "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strut-demo-port-sync${US}missing"* ]]
  [[ "$output" == *"strut-demo-nightly-backup${US}missing"* ]]
}

@test "timers_drift: orphaned unit with no matching config section is flagged" {
  _write_timers_conf
  _fake_systemd_setup
  timers_install "demo" "$STACK_DIR" >/dev/null

  : > "$STRUT_TIMERS_UNIT_DIR/strut-demo-stale-job.timer"
  : > "$STRUT_TIMERS_UNIT_DIR/strut-demo-stale-job.service"

  run timers_drift "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strut-demo-stale-job${US}orphaned"* ]]
}

@test "timers_drift: no timers.conf is a clean no-op" {
  _fake_systemd_setup
  run timers_drift "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "timers_drift: no systemctl is a clean no-op" {
  _write_timers_conf
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "systemctl" ]; then
      return 1
    fi
    builtin command "$@"
  }
  export -f command

  run timers_drift "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── timers_drift_report ───────────────────────────────────────────────────────

@test "timers_drift_report: no drift renders the empty state" {
  _write_timers_conf
  _fake_systemd_setup
  timers_install "demo" "$STACK_DIR" >/dev/null

  run timers_drift_report "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no timer drift"* ]]
}

@test "timers_drift_report: text mode renders a Unit/Reason table" {
  _write_timers_conf
  _fake_systemd_setup

  run timers_drift_report "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"strut-demo-port-sync"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "timers_drift_report: JSON mode emits {timers:[{unit,reason}]}" {
  _write_timers_conf
  _fake_systemd_setup
  export OUTPUT_MODE=json

  run timers_drift_report "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"unit":"strut-demo-port-sync"'* ]]
  [[ "$output" == *'"reason":"missing"'* ]]
}

@test "timers_drift_report: JSON mode emits an empty array when there's no drift" {
  _write_timers_conf
  _fake_systemd_setup
  timers_install "demo" "$STACK_DIR" >/dev/null
  export OUTPUT_MODE=json

  run timers_drift_report "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"timers":[]'* ]]
}

# ── timers_list ────────────────────────────────────────────────────────────────

@test "timers_list: no timers.conf prints empty state" {
  run timers_list "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no timers configured"* ]]
}

@test "timers_list: JSON mode emits an empty array with no timers.conf" {
  export OUTPUT_MODE=json
  run timers_list "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"timers":[]'* ]]
}

@test "timers_list: text mode shows configured timer names and schedule" {
  _write_timers_conf
  _fake_systemd_setup
  run timers_list "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"port-sync"* ]]
  [[ "$output" == *"60s"* ]]
  [[ "$output" == *"nightly-backup"* ]]
  [[ "$output" == *"daily 03:00"* ]]
}

@test "timers_list: JSON mode includes exec/schedule per timer" {
  _write_timers_conf
  _fake_systemd_setup
  export OUTPUT_MODE=json
  run timers_list "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"port-sync"'* ]]
  [[ "$output" == *'"unit":"strut-demo-port-sync"'* ]]
  [[ "$output" == *'"schedule":"60s"'* ]]
}

@test "_timers_lookup_next_last: parses NEXT/LAST columns from systemctl list-timers output" {
  local lt_output
  lt_output="Wed 2026-07-22 03:00:00 UTC  2h 40min left  Tue 2026-07-21 03:00:00 UTC  21h ago  strut-demo-nightly-backup.timer  strut-demo-nightly-backup.service"
  run _timers_lookup_next_last "strut-demo-nightly-backup" "$lt_output"
  [ "$status" -eq 0 ]
  [ "$output" = "Wed 2026-07-22 03:00:00 UTC|Tue 2026-07-21 03:00:00 UTC" ]
}

@test "_timers_lookup_next_last: unit missing from output yields an empty pair" {
  run _timers_lookup_next_last "strut-demo-nightly-backup" "some other unit entirely"
  [ "$status" -eq 0 ]
  [ "$output" = "|" ]
}

@test "timers_list: text mode surfaces next/last run parsed from systemctl list-timers" {
  _write_timers_conf
  _fake_systemd_setup
  local lt_file="$TEST_TMP/list_timers_output.txt"
  cat > "$lt_file" <<'EOF'
Wed 2026-07-22 03:00:00 UTC  2h 40min left  Tue 2026-07-21 03:00:00 UTC  21h ago  strut-demo-nightly-backup.timer  strut-demo-nightly-backup.service
EOF
  export FAKE_LIST_TIMERS_OUTPUT="$lt_file"

  run timers_list "demo" "$STACK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wed 2026-07-22 03:00:00 UTC"* ]]
  [[ "$output" == *"Tue 2026-07-21 03:00:00 UTC"* ]]
}

# ── cmd_timers dispatch ────────────────────────────────────────────────────────

setup_cmd_timers() {
  source "$LIB/config.sh"
  source "$LIB/topology.sh"
  source "$LIB/cmd_timers.sh"

  is_running_on_vps() { return 1; }
  export -f is_running_on_vps
  ssh() { echo "ssh $*"; return 0; }
  export -f ssh
  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  export -f build_ssh_opts

  export CMD_STACK="demo"
  export CMD_STACK_DIR="$STACK_DIR"
  export CMD_ENV_FILE="$TEST_TMP/nonexistent.env"
  export CMD_ENV_NAME="prod"
}

@test "cmd_timers: --help / help prints usage" {
  setup_cmd_timers
  run cmd_timers help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"install"* ]]
  [[ "$output" == *"remove"* ]]
}

@test "cmd_timers: unknown subcommand fails cleanly" {
  setup_cmd_timers
  run cmd_timers bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown timers subcommand"* ]]
}

@test "cmd_timers: dispatches via SSH when VPS_HOST is set" {
  setup_cmd_timers
  export VPS_HOST="vps.example.com"

  run cmd_timers list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"timers list"* ]]
}

@test "cmd_timers: forwards --json through remote dispatch" {
  setup_cmd_timers
  export VPS_HOST="vps.example.com"
  export CMD_JSON="--json"

  run cmd_timers list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"timers list --json"* ]]
}

@test "cmd_timers: no --json flag omitted from remote dispatch when CMD_JSON is unset" {
  setup_cmd_timers
  export VPS_HOST="vps.example.com"
  unset CMD_JSON

  run cmd_timers list
  [ "$status" -eq 0 ]
  [[ "$output" != *"--json"* ]]
}

@test "cmd_timers: runs locally when VPS_HOST is empty" {
  setup_cmd_timers
  export VPS_HOST=""

  run cmd_timers list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no timers configured"* ]]
  [[ "$output" != *"ssh "* ]]
}

@test "cmd_timers: drift runs locally via timers_drift_report when VPS_HOST is empty" {
  setup_cmd_timers
  export VPS_HOST=""

  run cmd_timers drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"no timer drift"* ]]
  [[ "$output" != *"ssh "* ]]
}

@test "cmd_timers: drift dispatches via SSH when VPS_HOST is set, forwarding --json" {
  setup_cmd_timers
  export VPS_HOST="vps.example.com"
  export CMD_JSON="--json"

  run cmd_timers drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh"* ]]
  [[ "$output" == *"timers drift --json"* ]]
}

@test "cmd_timers: defaults to 'list' with no subcommand" {
  setup_cmd_timers
  export VPS_HOST=""

  run cmd_timers
  [ "$status" -eq 0 ]
  [[ "$output" == *"no timers configured"* ]]
}

# ── deploy_stack → timers_install wiring ────────────────────────────────────
# Confirms the post-deploy call site (lib/deploy.sh, after the post_deploy
# hook) actually fires timers_install with (stack, stack_dir) on a
# successful deploy. Mirrors the full-success harness in
# tests/test_deploy_up_failure.bats (same stub set) plus a passing
# _bg_wait_healthy — deploy_stack health-gates after `up -d` otherwise.

@test "deploy_stack: fires timers_install with (stack, stack_dir) on a successful deploy" {
  source "$LIB/config.sh"
  source "$LIB/deploy.sh"

  registry_login() { :; }
  docker_pull_stack() { :; }
  docker_require_images() { return 0; }
  rollback_save_snapshot() { :; }
  export_volume_paths() { :; }
  fire_hook() { return 0; }
  fire_hook_or_warn() { :; }
  fire_first_run_hook() { :; }
  maybe_apply_db_schema() { :; }
  notify_event() { :; }
  print_banner() { :; }
  require_cmd() { :; }
  is_running_on_vps() { return 1; }
  _bg_wait_healthy() { return 0; }
  export -f registry_login docker_pull_stack docker_require_images \
            rollback_save_snapshot export_volume_paths fire_hook \
            fire_hook_or_warn fire_first_run_hook maybe_apply_db_schema \
            notify_event print_banner require_cmd is_running_on_vps \
            _bg_wait_healthy

  docker() { return 0; }
  export -f docker

  local timers_install_calls="$TEST_TMP/timers_install_calls"
  : > "$timers_install_calls"
  timers_install() { echo "$*" >> "$timers_install_calls"; return 0; }
  export -f timers_install

  local hub_dir="$TEST_TMP/stacks/hub"
  mkdir -p "$hub_dir"
  cat > "$hub_dir/docker-compose.yml" <<'EOF'
services:
  app:
    image: hub-app
EOF
  cat > "$hub_dir/services.conf" <<'EOF'
BUILD_MODE=none
EOF
  local env_file="$TEST_TMP/.prod.env"
  : > "$env_file"

  export DRY_RUN="false"
  export PRE_DEPLOY_VALIDATE="false"
  export SKIP_VALIDATION="false"

  run deploy_stack "hub" "$env_file" ""
  [ "$status" -eq 0 ]
  [ -s "$timers_install_calls" ]
  [ "$(cat "$timers_install_calls")" = "hub $hub_dir" ]
}
