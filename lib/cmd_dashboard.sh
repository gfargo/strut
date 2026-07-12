#!/usr/bin/env bash
# ==================================================
# lib/cmd_dashboard.sh — Lightweight fleet status dashboard
# ==================================================
# Provides:
#   cmd_dashboard [--port <N>] [--bind <addr>] [--json] [--help]
#
# Starts a zero-dependency (socat) HTTP server exposing fleet + stack
# health as an auto-refreshing HTML page (default) or as JSON. Binds to
# 127.0.0.1 by default — no auth, meant to be fronted by a reverse proxy
# if exposed beyond localhost.
#
# Endpoints:
#   GET /              HTML dashboard (or JSON when started with --json)
#   GET /api/fleet     strut fleet status --json
#   GET /api/stacks    strut status-all --json
#   GET /api/drift     Per-stack drift status, aggregated into a JSON array

set -euo pipefail

_DASH_DEFAULT_PORT=8484
_DASH_DEFAULT_BIND="127.0.0.1"
_DASH_DEFAULT_TTL=30

_usage_dashboard() {
  echo ""
  echo "Usage: strut dashboard [options]"
  echo ""
  echo "Starts a read-only HTTP server showing fleet + stack health."
  echo ""
  echo "Options:"
  echo "  --port <N>     HTTP listen port (default: $_DASH_DEFAULT_PORT)"
  echo "  --bind <addr>  Bind address (default: $_DASH_DEFAULT_BIND — localhost only)"
  echo "  --json         JSON-only mode: GET / returns JSON instead of HTML"
  echo "  --help         Show this help"
  echo ""
  echo "Endpoints:"
  echo "  GET /              HTML dashboard (or JSON in --json mode)"
  echo "  GET /api/fleet     strut fleet status --json"
  echo "  GET /api/stacks    strut status-all --json"
  echo "  GET /api/drift     Per-stack drift status, aggregated"
  echo ""
  echo "Examples:"
  echo "  strut dashboard --port 8484"
  echo "  strut dashboard --port 8484 --json"
  echo ""
}

# cmd_dashboard [--port <N>] [--bind <addr>] [--json] [--help]
cmd_dashboard() {
  local port="$_DASH_DEFAULT_PORT"
  local bind="$_DASH_DEFAULT_BIND"
  local json_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      --port=*) port="${1#*=}"; shift ;;
      --bind) bind="$2"; shift 2 ;;
      --bind=*) bind="${1#*=}"; shift ;;
      --json) json_only=true; shift ;;
      --help|-h) _usage_dashboard; return 0 ;;
      *) _usage_dashboard; fail "Unknown dashboard option: $1"; return 1 ;;
    esac
  done

  command -v socat >/dev/null 2>&1 || fail "dashboard requires 'socat' (apt install socat / brew install socat)"

  local cache_dir
  cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/strut-dashboard.XXXXXX")
  if declare -F strut_register_cleanup >/dev/null; then
    strut_register_cleanup "rm -rf '$cache_dir'"
  fi
  # socat blocks in the foreground until Ctrl+C; the entrypoint's EXIT trap
  # (STRUT_CLEANUPS chain, registered above) does not fire on SIGINT/SIGTERM
  # by itself, so this needs its own handlers — same pattern as cmd_group.sh.
  # shellcheck disable=SC2064 # cache_dir is fixed at registration time, not signal time
  trap "rm -rf '$cache_dir'; exit 130" INT
  # shellcheck disable=SC2064
  trap "rm -rf '$cache_dir'; exit 143" TERM

  # Exported for the handler subprocess spawned per-connection by socat's
  # `fork` — each connection gets a fresh shell, so state (cache dir, target
  # binary/project) has to travel via the environment, not shell variables.
  export _DASH_CACHE_DIR="$cache_dir"
  export _DASH_CACHE_TTL="$_DASH_DEFAULT_TTL"
  export _DASH_JSON_ONLY="$json_only"
  export _DASH_STRUT_HOME="$STRUT_HOME"
  export _DASH_STRUT_BIN="$STRUT_HOME/strut"
  export _DASH_PROJECT_ROOT="$CLI_ROOT"
  export STRUT_PROJECT="$CLI_ROOT"

  log "Dashboard on http://$bind:$port (Ctrl+C to stop)"
  echo ""

  # Written to a file and run via EXEC (fork+exec), not SYSTEM (fork+`/bin/sh
  # -c`): SYSTEM's shell is whatever /bin/sh is on the host (dash on
  # Debian/Ubuntu), which chokes on this script's `source` and `pipefail`
  # usage. EXEC execs the file directly, so its own `#!/usr/bin/env bash`
  # shebang decides the interpreter regardless of the system's /bin/sh.
  local handler_file="$cache_dir/handler.sh"
  {
    echo '#!/usr/bin/env bash'
    _dashboard_handler_script
  } > "$handler_file"
  chmod +x "$handler_file"

  socat "TCP-LISTEN:$port,bind=$bind,fork,reuseaddr" "EXEC:$handler_file"
}

# ── Per-connection HTTP handler (spawned by socat) ─────────────────────────────

_dashboard_handler_script() {
  cat << 'HANDLER'
read -r method path _version
while IFS= read -r line; do
  line="${line%$'\r'}"
  [ -z "$line" ] && break
done

source "$_DASH_STRUT_HOME/lib/utils.sh" 2>/dev/null || true
source "$_DASH_STRUT_HOME/lib/cmd_dashboard.sh" 2>/dev/null || true

case "$path" in
  /api/fleet)
    _dashboard_respond "200 OK" "application/json" "$(_dashboard_cache_fetch fleet _dashboard_fleet_json)"
    ;;
  /api/stacks)
    _dashboard_respond "200 OK" "application/json" "$(_dashboard_cache_fetch stacks _dashboard_stacks_json)"
    ;;
  /api/drift)
    _dashboard_respond "200 OK" "application/json" "$(_dashboard_cache_fetch drift _dashboard_drift_json)"
    ;;
  /)
    fleet_body=$(_dashboard_cache_fetch fleet _dashboard_fleet_json)
    stacks_body=$(_dashboard_cache_fetch stacks _dashboard_stacks_json)
    if [ "${_DASH_JSON_ONLY:-false}" = "true" ]; then
      _dashboard_respond "200 OK" "application/json" "{\"fleet\":$fleet_body,\"stacks\":$stacks_body}"
    else
      _dashboard_respond "200 OK" "text/html; charset=utf-8" "$(_dashboard_render_html "$fleet_body" "$stacks_body" "$(_dashboard_cache_age fleet)")"
    fi
    ;;
  *)
    _dashboard_respond "404 Not Found" "text/plain" "not found"
    ;;
esac
HANDLER
}

# _dashboard_respond <status-line> <content-type> <body>
_dashboard_respond() {
  local status="$1" ctype="$2" body="$3"
  local len
  len=$(printf '%s' "$body" | wc -c | tr -d ' ')
  printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$status" "$ctype" "$len" "$body"
}

# ── Cached data producers ──────────────────────────────────────────────────────
# socat's `fork` spawns one handler process per connection, so an in-memory
# cache wouldn't survive between requests — results are cached to files
# keyed by name, keyed on mtime age against _DASH_CACHE_TTL.

# _dashboard_file_mtime <file> — last-modified time as a unix timestamp, or 0
_dashboard_file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# _dashboard_cache_fetch <key> <cmd> [args...]
_dashboard_cache_fetch() {
  local key="$1"; shift
  local ttl="${_DASH_CACHE_TTL:-$_DASH_DEFAULT_TTL}"
  local dir="${_DASH_CACHE_DIR:-}"

  if [ -z "$dir" ]; then
    "$@"
    return
  fi

  local file="$dir/$key.json"
  if [ -f "$file" ]; then
    local mtime now age
    mtime=$(_dashboard_file_mtime "$file")
    now=$(date +%s)
    age=$((now - mtime))
    if [ "$age" -lt "$ttl" ]; then
      cat "$file"
      return 0
    fi
  fi

  local out
  out=$("$@" 2>/dev/null) || out=""
  [ -n "$out" ] || out='{"error":"command failed"}'
  printf '%s' "$out" > "$file.tmp" && mv "$file.tmp" "$file"
  printf '%s' "$out"
}

# _dashboard_cache_age <key> — seconds since <key>.json was last (re)written,
# for display only; empty if the cache dir/file isn't available.
_dashboard_cache_age() {
  local key="$1"
  local dir="${_DASH_CACHE_DIR:-}"
  [ -n "$dir" ] || return 0

  local file="$dir/$key.json"
  [ -f "$file" ] || return 0

  local mtime now
  mtime=$(_dashboard_file_mtime "$file")
  now=$(date +%s)
  printf '%s' "$((now - mtime))"
}

_dashboard_fleet_json() {
  "$_DASH_STRUT_BIN" fleet status --json
}

_dashboard_stacks_json() {
  "$_DASH_STRUT_BIN" status-all --json
}

# _dashboard_drift_json — no fleet-wide drift aggregator exists elsewhere, so
# this iterates every stack directory and shells out to `strut <stack> drift
# report --json` (using whatever env that invocation defaults to), wrapping
# the per-stack reports into a single JSON array.
_dashboard_drift_json() {
  local root="${_DASH_PROJECT_ROOT:-$CLI_ROOT}"
  local first=1 d name entry

  printf '['
  for d in "$root"/stacks/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    [ "$name" = "shared" ] && continue

    entry=$("$_DASH_STRUT_BIN" "$name" drift report --json 2>/dev/null) || entry=""
    [ -n "$entry" ] || entry="{\"stack\":\"$name\",\"status\":\"error\"}"

    if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
    printf '%s' "$entry"
  done
  printf ']'
}

# ── HTML rendering ──────────────────────────────────────────────────────────────

# _dashboard_html_escape <text>
_dashboard_html_escape() {
  local s="$1"
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"
  printf '%s' "$s"
}

# _dashboard_render_html <fleet-json> <stacks-json> [cache-age-seconds]
#
# Pure function — degrades to a raw <pre> dump per section when jq is
# unavailable or the JSON blob is invalid/empty.
_dashboard_render_html() {
  local fleet_json="$1"
  local stacks_json="$2"
  local age="${3:-}"
  local refresh_label
  if [[ "$age" =~ ^[0-9]+$ ]]; then
    refresh_label="${age}s ago"
  else
    printf -v refresh_label '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  fi

  echo "<!DOCTYPE html>"
  echo "<html><head><meta charset=\"utf-8\">"
  echo "<meta http-equiv=\"refresh\" content=\"30\">"
  echo "<title>strut fleet dashboard</title>"
  echo "<style>"
  echo "body{font-family:monospace;background:#111;color:#eee;padding:1.5rem}"
  echo "table{border-collapse:collapse;margin-bottom:1.5rem}"
  echo "th,td{padding:.3rem .8rem;text-align:left;border-bottom:1px solid #333}"
  echo "th{color:#888;text-transform:uppercase;font-size:.8em}"
  echo ".ok{color:#4caf50}.warn{color:#e0a030}.err{color:#e05050}"
  echo "</style></head><body>"
  echo "<h2>strut fleet dashboard</h2>"
  echo "<p>Last refresh: $refresh_label</p>"

  # The issue mock's host table has a LAST DEPLOY column, but `fleet status
  # --json` (lib/cmd_fleet.sh) has no per-host deploy timestamp to show there
  # — only branch/behind/ahead/dirty/head_sha. Branch is shown instead;
  # last-deploy is surfaced per-stack in the table below, from status-all.
  if command -v jq >/dev/null 2>&1 && printf '%s' "$fleet_json" | jq -e . >/dev/null 2>&1; then
    echo "<table><tr><th>Host</th><th>Status</th><th>Branch</th><th>Behind</th><th>Dirty</th></tr>"
    printf '%s' "$fleet_json" | jq -r '.hosts[]? | [.host, (.status//"-"), (.branch//"-"), ((.behind//"-")|tostring), ((.dirty//"-")|tostring)] | @tsv' |
      while IFS=$'\t' read -r host hstatus branch behind dirty; do
        local glyph="ok" symbol="OK"
        if [ "$hstatus" != "ok" ]; then
          glyph="err"; symbol="ERR"
        elif [ "$behind" != "0" ] || [ "$dirty" != "0" ]; then
          glyph="warn"; symbol="WARN"
        fi
        printf '<tr><td>%s</td><td class="%s">%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
          "$(_dashboard_html_escape "$host")" "$glyph" "$symbol" \
          "$(_dashboard_html_escape "$branch")" "$(_dashboard_html_escape "$behind")" "$(_dashboard_html_escape "$dirty")"
      done
    echo "</table>"
  else
    echo "<h3>Hosts</h3>"
    echo "<pre>$(_dashboard_html_escape "$fleet_json")</pre>"
  fi

  echo "<h3>Stacks</h3>"
  if command -v jq >/dev/null 2>&1 && printf '%s' "$stacks_json" | jq -e . >/dev/null 2>&1; then
    echo "<table><tr><th>Stack</th><th>Health</th><th>Last Deploy</th><th>Backup Age</th></tr>"
    printf '%s' "$stacks_json" | jq -r '.stacks[]? | [.name, (.health//"-"), (.last_deploy//"-"), (.backup_age//"-")] | @tsv' |
      while IFS=$'\t' read -r name health last_deploy backup_age; do
        local glyph=""
        case "$health" in
          healthy)  glyph="ok" ;;
          degraded) glyph="warn" ;;
          down)     glyph="err" ;;
        esac
        printf '<tr><td>%s</td><td class="%s">%s</td><td>%s</td><td>%s</td></tr>\n' \
          "$(_dashboard_html_escape "$name")" "$glyph" "$(_dashboard_html_escape "$health")" \
          "$(_dashboard_html_escape "$last_deploy")" "$(_dashboard_html_escape "$backup_age")"
      done
    echo "</table>"
  else
    echo "<pre>$(_dashboard_html_escape "$stacks_json")</pre>"
  fi

  echo "</body></html>"
}
