#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_dashboard.bats — Tests for strut dashboard
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"

  export REAL_CLI_ROOT="$CLI_ROOT"
  export CLI_ROOT="$TEST_TMP"
  export STRUT_HOME="$REAL_CLI_ROOT"
  mkdir -p "$CLI_ROOT/stacks"

  source "$REAL_CLI_ROOT/lib/cmd_dashboard.sh"
}

teardown() {
  common_teardown
}

# ── Arg parsing / socat guard ────────────────────────────────────────────────

_stub_socat_recorder() {
  # shellcheck disable=SC2317
  socat() { printf 'socat_args:%s\n' "$*" | head -c 400; return 0; }
  export -f socat
}

@test "cmd_dashboard: default port and bind" {
  _stub_socat_recorder
  run cmd_dashboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"TCP-LISTEN:8484,bind=127.0.0.1,fork,reuseaddr"* ]]
}

@test "cmd_dashboard: --port and --bind override defaults" {
  _stub_socat_recorder
  run cmd_dashboard --port 9999 --bind 0.0.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"TCP-LISTEN:9999,bind=0.0.0.0,fork,reuseaddr"* ]]
}

@test "cmd_dashboard: --json exports JSON-only mode for the handler subprocess" {
  # shellcheck disable=SC2317
  socat() { printf 'json_only=%s' "$_DASH_JSON_ONLY"; return 0; }
  export -f socat
  run cmd_dashboard --port 9999 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"json_only=true"* ]]
}

@test "cmd_dashboard: unknown flag fails" {
  run cmd_dashboard --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown dashboard option"* ]]
}

@test "cmd_dashboard: --help prints usage without failing" {
  run cmd_dashboard --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: strut dashboard"* ]]
}

@test "cmd_dashboard: missing socat fails with install hint" {
  PATH="" run cmd_dashboard --port 9999
  [ "$status" -ne 0 ]
  [[ "$output" == *"socat"* ]]
}

@test "cmd_dashboard: uses EXEC (not SYSTEM) so the handler always runs under bash" {
  _stub_socat_recorder
  run cmd_dashboard --port 9999
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXEC:"* ]]
  [[ "$output" != *"SYSTEM:"* ]]
}

@test "cmd_dashboard: writes an executable handler file with a bash shebang" {
  local captured_path=""
  # shellcheck disable=SC2317
  socat() {
    for arg in "$@"; do
      [[ "$arg" == EXEC:* ]] && captured_path="${arg#EXEC:}"
    done
    printf '%s' "$captured_path" > "$BATS_TEST_TMPDIR/handler_path"
    return 0
  }
  export -f socat
  run cmd_dashboard --port 9999
  [ "$status" -eq 0 ]
  local handler_path
  handler_path=$(cat "$BATS_TEST_TMPDIR/handler_path")
  [ -x "$handler_path" ]
  [ "$(head -n1 "$handler_path")" = "#!/usr/bin/env bash" ]
}

@test "cmd_dashboard: registers INT and TERM traps that remove the cache dir" {
  _stub_socat_recorder
  # `run` captures output via a subshell, which would swallow the trap along
  # with it — call directly (output redirected) so the trap lands in this shell.
  cmd_dashboard --port 9999 >/dev/null
  local int_trap term_trap
  int_trap=$(trap -p INT)
  term_trap=$(trap -p TERM)
  trap - INT TERM
  [[ "$int_trap" == *"rm -rf"*"strut-dashboard."* ]]
  [[ "$term_trap" == *"rm -rf"*"strut-dashboard."* ]]
}

# ── _dashboard_cache_fetch ───────────────────────────────────────────────────

@test "_dashboard_cache_fetch: runs the command and caches the result" {
  export _DASH_CACHE_DIR="$BATS_TEST_TMPDIR"
  export _DASH_CACHE_TTL=30
  _dash_counter() { echo '{"n":1}'; }
  export -f _dash_counter

  run _dashboard_cache_fetch mykey _dash_counter
  [ "$output" = '{"n":1}' ]
  [ -f "$BATS_TEST_TMPDIR/mykey.json" ]
}

@test "_dashboard_cache_fetch: serves cached value within TTL without re-running" {
  export _DASH_CACHE_DIR="$BATS_TEST_TMPDIR"
  export _DASH_CACHE_TTL=300
  echo '{"cached":true}' > "$BATS_TEST_TMPDIR/cachedkey.json"
  _dash_should_not_run() { echo '{"cached":false}'; }
  export -f _dash_should_not_run

  run _dashboard_cache_fetch cachedkey _dash_should_not_run
  [ "$output" = '{"cached":true}' ]
}

@test "_dashboard_cache_fetch: falls back to error JSON on command failure" {
  export _DASH_CACHE_DIR="$BATS_TEST_TMPDIR"
  export _DASH_CACHE_TTL=30
  _dash_failing() { return 1; }
  export -f _dash_failing

  run _dashboard_cache_fetch failkey _dash_failing
  [[ "$output" == *'"error"'* ]]
}

# ── _dashboard_respond ───────────────────────────────────────────────────────

@test "_dashboard_respond: emits status line, content-type, and accurate length" {
  run _dashboard_respond "200 OK" "application/json" '{"a":1}'
  [[ "$output" == *"HTTP/1.1 200 OK"* ]]
  [[ "$output" == *"Content-Type: application/json"* ]]
  [[ "$output" == *"Content-Length: 7"* ]]
  [[ "$output" == *'{"a":1}'* ]]
}

# ── _dashboard_drift_json ────────────────────────────────────────────────────

@test "_dashboard_drift_json: aggregates per-stack drift reports into a JSON array" {
  mkdir -p "$CLI_ROOT/stacks/api" "$CLI_ROOT/stacks/worker"
  _dash_stub_strut() {
    case "$1" in
      api)    echo '{"stack":"api","status":"no_drift"}' ;;
      worker) echo '{"stack":"worker","status":"drift_detected"}' ;;
    esac
  }
  export -f _dash_stub_strut
  export _DASH_STRUT_BIN=_dash_stub_strut
  export _DASH_PROJECT_ROOT="$CLI_ROOT"

  run _dashboard_drift_json
  [ "$status" -eq 0 ]
  [[ "$output" == \[*\] ]]
  [[ "$output" == *'"stack":"api","status":"no_drift"'* ]]
  [[ "$output" == *'"stack":"worker","status":"drift_detected"'* ]]
}

@test "_dashboard_drift_json: skips the 'shared' directory" {
  mkdir -p "$CLI_ROOT/stacks/api" "$CLI_ROOT/stacks/shared"
  _dash_stub_strut() { echo "{\"stack\":\"$1\"}"; }
  export -f _dash_stub_strut
  export _DASH_STRUT_BIN=_dash_stub_strut
  export _DASH_PROJECT_ROOT="$CLI_ROOT"

  run _dashboard_drift_json
  [[ "$output" != *'"stack":"shared"'* ]]
  [[ "$output" == *'"stack":"api"'* ]]
}

@test "_dashboard_drift_json: a failing stack yields an error entry, loop continues" {
  mkdir -p "$CLI_ROOT/stacks/api" "$CLI_ROOT/stacks/broken"
  _dash_stub_strut() {
    case "$1" in
      broken) return 1 ;;
      *)      echo "{\"stack\":\"$1\",\"status\":\"no_drift\"}" ;;
    esac
  }
  export -f _dash_stub_strut
  export _DASH_STRUT_BIN=_dash_stub_strut
  export _DASH_PROJECT_ROOT="$CLI_ROOT"

  run _dashboard_drift_json
  [[ "$output" == *'"stack":"broken","status":"error"'* ]]
  [[ "$output" == *'"stack":"api","status":"no_drift"'* ]]
}

@test "_dashboard_drift_json: no stacks yields an empty array" {
  export _DASH_STRUT_BIN=true
  export _DASH_PROJECT_ROOT="$CLI_ROOT"

  run _dashboard_drift_json
  [ "$output" = "[]" ]
}

# ── _dashboard_render_html ───────────────────────────────────────────────────

_fleet_fixture='{"hosts":[{"host":"compass","status":"ok","branch":"main","behind":"0","ahead":"0","dirty":0,"head_sha":"abc1234"},{"host":"harbor","status":"ok","branch":"main","behind":"3","ahead":"0","dirty":1,"head_sha":"def5678"}],"branch":"main"}'
_stacks_fixture='{"timestamp":"2026-07-12T00:00:00Z","stacks":[{"name":"my-app","health":"healthy","last_deploy":"2h ago","backup_age":"4h ago"}],"summary":{"total":1,"healthy":1,"degraded":0,"down":0,"unknown":0}}'

@test "_dashboard_cache_age: reports seconds since the cache file was written" {
  export _DASH_CACHE_DIR="$BATS_TEST_TMPDIR"
  echo '{}' > "$BATS_TEST_TMPDIR/agekey.json"
  touch -d "@$(($(date +%s) - 15))" "$BATS_TEST_TMPDIR/agekey.json"

  run _dashboard_cache_age agekey
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 14 ]
}

@test "_dashboard_cache_age: empty when the cache file doesn't exist" {
  export _DASH_CACHE_DIR="$BATS_TEST_TMPDIR"
  run _dashboard_cache_age missingkey
  [ -z "$output" ]
}

@test "_dashboard_render_html: includes a 30s meta-refresh tag" {
  run _dashboard_render_html "$_fleet_fixture" "$_stacks_fixture"
  [[ "$output" == *'<meta http-equiv="refresh" content="30">'* ]]
}

@test "_dashboard_render_html: renders host rows from fleet JSON" {
  run _dashboard_render_html "$_fleet_fixture" "$_stacks_fixture"
  [[ "$output" == *"compass"* ]]
  [[ "$output" == *"harbor"* ]]
}

@test "_dashboard_render_html: renders stack rows from stacks JSON" {
  run _dashboard_render_html "$_fleet_fixture" "$_stacks_fixture"
  [[ "$output" == *"my-app"* ]]
  [[ "$output" == *"healthy"* ]]
}

@test "_dashboard_render_html: degrades to a <pre> dump when jq is unavailable" {
  PATH="" run _dashboard_render_html "$_fleet_fixture" "$_stacks_fixture"
  [[ "$output" == *"<pre>"* ]]
}

@test "_dashboard_render_html: shows relative cache freshness when an age is given" {
  run _dashboard_render_html "$_fleet_fixture" "$_stacks_fixture" 12
  [[ "$output" == *"Last refresh: 12s ago"* ]]
}

@test "_dashboard_render_html: falls back to an absolute timestamp without an age" {
  run _dashboard_render_html "$_fleet_fixture" "$_stacks_fixture"
  [[ "$output" == *"Last refresh: "*"Z"* ]]
  [[ "$output" != *"Last refresh: "*"s ago"* ]]
}

@test "_dashboard_render_html: escapes HTML-significant characters" {
  local malicious='{"hosts":[{"host":"<script>alert(1)</script>","status":"ok"}],"branch":"main"}'
  run _dashboard_render_html "$malicious" "$_stacks_fixture"
  [[ "$output" != *"<script>alert(1)</script>"* ]]
  [[ "$output" == *"&lt;script&gt;"* ]]
}
