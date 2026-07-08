#!/usr/bin/env bash
# ==================================================
# lib/cmd_webhook.sh — Push-to-deploy automation
# ==================================================
# Provides:
#   cmd_webhook poll    — poll origin for new commits, auto-release
#   cmd_webhook serve   — HTTP webhook receiver for GitHub/GitLab push events
#   cmd_webhook install — generate systemd service for persistence

set -euo pipefail

_usage_webhook() {
  echo ""
  echo "Usage: strut webhook <command> [options]"
  echo ""
  echo "Commands:"
  echo "  poll [--interval <sec>] [--branch <name>] [--stack <name>] [--once]"
  echo "       Poll origin for new commits and auto-release affected stacks."
  echo ""
  echo "  serve [--port <N>] [--secret <hmac>] [--branch <name>]"
  echo "       Start HTTP webhook receiver for GitHub/GitLab push events."
  echo ""
  echo "  install [--mode poll|serve] [--interval <sec>] [--port <N>]"
  echo "       Generate a systemd service unit for persistent operation."
  echo ""
  echo "Options:"
  echo "  --interval <sec>   Poll interval in seconds (default: 60)"
  echo "  --branch <name>    Only deploy on pushes to this branch (default: DEFAULT_BRANCH or main)"
  echo "  --stack <name>     Only deploy this stack (default: all mapped stacks)"
  echo "  --once             Run one poll cycle and exit (for cron)"
  echo "  --port <N>         HTTP listen port for serve mode (default: 9876)"
  echo "  --secret <hmac>    HMAC secret for webhook signature validation"
  echo ""
  echo "Examples:"
  echo "  strut webhook poll                         # poll every 60s, deploy all"
  echo "  strut webhook poll --interval 30 --once    # single check (for cron)"
  echo "  strut webhook serve --port 9876 --secret \$WEBHOOK_SECRET"
  echo "  strut webhook install --mode poll"
  echo ""
}

cmd_webhook() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    poll)    _webhook_poll "$@" ;;
    serve)   _webhook_serve "$@" ;;
    install) _webhook_install "$@" ;;
    ""|help) _usage_webhook ;;
    *)       _usage_webhook; fail "Unknown webhook subcommand: $subcmd" ;;
  esac
}

# ── Poll Mode ─────────────────────────────────────────────────────────────────

_webhook_poll() {
  local interval=60
  local branch="${DEFAULT_BRANCH:-main}"
  local stack_filter=""
  local once=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval) interval="$2"; shift 2 ;;
      --interval=*) interval="${1#*=}"; shift ;;
      --branch) branch="$2"; shift 2 ;;
      --branch=*) branch="${1#*=}"; shift ;;
      --stack) stack_filter="$2"; shift 2 ;;
      --stack=*) stack_filter="${1#*=}"; shift ;;
      --once) once=true; shift ;;
      *) shift ;;
    esac
  done

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local state_file="$cli_root/.webhook-last-sha"

  log "Webhook poll: branch=$branch interval=${interval}s stack=${stack_filter:-all}"

  while true; do
    _poll_cycle "$cli_root" "$branch" "$stack_filter" "$state_file"
    $once && break
    sleep "$interval"
  done
}

_poll_cycle() {
  local cli_root="$1"
  local branch="$2"
  local stack_filter="$3"
  local state_file="$4"

  # Fetch latest from origin
  if ! git -C "$cli_root" fetch origin "$branch" --quiet 2>/dev/null; then
    warn "webhook poll: fetch failed (network?)"
    return 0
  fi

  local current_sha
  current_sha=$(git -C "$cli_root" rev-parse "origin/$branch" 2>/dev/null) || return 0

  local last_sha=""
  [ -f "$state_file" ] && last_sha=$(cat "$state_file")

  if [ "$current_sha" = "$last_sha" ]; then
    return 0  # No new commits
  fi

  log "webhook: new commits detected (${last_sha:0:7}..${current_sha:0:7})"

  # Determine which stacks changed
  local changed_stacks
  if [ -n "$last_sha" ]; then
    changed_stacks=$(_detect_changed_stacks "$cli_root" "$last_sha" "$current_sha")
  else
    changed_stacks=$(_all_stacks "$cli_root")
  fi

  # Apply stack filter
  if [ -n "$stack_filter" ]; then
    changed_stacks=$(echo "$changed_stacks" | grep -xF "$stack_filter" || true)
  fi

  if [ -z "$changed_stacks" ]; then
    log "webhook: no stack changes detected, skipping release"
    echo "$current_sha" > "$state_file"
    return 0
  fi

  # Pull the changes locally first
  git -C "$cli_root" reset --hard "origin/$branch" --quiet 2>/dev/null || true

  # Release each affected stack
  local stack
  while IFS= read -r stack; do
    [ -n "$stack" ] || continue
    log "webhook: releasing $stack"
    _webhook_release_stack "$stack" || warn "webhook: release failed for $stack"
  done <<< "$changed_stacks"

  # Record the deployed SHA
  echo "$current_sha" > "$state_file"
  ok "webhook: deployed ${current_sha:0:7}"
}

_detect_changed_stacks() {
  local cli_root="$1"
  local from_sha="$2"
  local to_sha="$3"

  # Get list of changed files between the two commits
  local changed_files
  changed_files=$(git -C "$cli_root" diff --name-only "$from_sha" "$to_sha" 2>/dev/null) || return 0

  # Map changed files to stacks
  echo "$changed_files" | grep "^stacks/" | cut -d/ -f2 | sort -u
}

_all_stacks() {
  local cli_root="$1"
  ls "$cli_root/stacks" 2>/dev/null | while read -r d; do
    [ -d "$cli_root/stacks/$d" ] && echo "$d"
  done
}

_webhook_release_stack() {
  local stack="$1"
  local env_name="${CMD_ENV_NAME:-prod}"
  local env_file
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  env_file="$cli_root/.${env_name}.env"
  [ -f "$env_file" ] || env_file="$cli_root/stacks/$stack/.${env_name}.env"
  [ -f "$env_file" ] || { warn "webhook: no env file for $stack ($env_name)"; return 1; }

  # Use validate_env_file to load connection info
  validate_env_file "$env_file" VPS_HOST || return 1

  local services=""
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "$services" 2>/dev/null) || true

  # Call the release pipeline
  if declare -F vps_release &>/dev/null; then
    vps_release "$stack" "$env_file" "$services"
  else
    # Fallback: just sync + deploy
    local deploy_dir
    deploy_dir=$(resolve_deploy_dir)
    fleet_sync "$VPS_USER" "$VPS_HOST" "${VPS_PORT:-22}" "${VPS_SSH_KEY:-}" "$deploy_dir" "${DEFAULT_BRANCH:-main}" "${GH_PAT:-}"
  fi
}

# ── Serve Mode (HTTP webhook receiver) ────────────────────────────────────────

_webhook_serve() {
  local port=9876
  local secret=""
  local branch="${DEFAULT_BRANCH:-main}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      --port=*) port="${1#*=}"; shift ;;
      --secret) secret="$2"; shift 2 ;;
      --secret=*) secret="${1#*=}"; shift ;;
      --branch) branch="$2"; shift 2 ;;
      --branch=*) branch="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$secret" ] || fail "webhook serve requires --secret <hmac-secret> for signature validation"
  command -v socat >/dev/null 2>&1 || fail "webhook serve requires 'socat' (apt install socat / brew install socat)"

  log "Webhook server starting on :$port (branch=$branch)"
  log "Configure GitHub webhook URL: http://<your-vps>:$port/webhook"
  echo ""

  # Export for the handler subprocess
  export _WEBHOOK_SECRET="$secret"
  export _WEBHOOK_BRANCH="$branch"
  export _WEBHOOK_CLI_ROOT="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  local handler_script
  handler_script=$(_webhook_handler_script)

  socat "TCP-LISTEN:$port,fork,reuseaddr" "SYSTEM:$handler_script"
}

_webhook_handler_script() {
  local cli_root="${_WEBHOOK_CLI_ROOT:-$CLI_ROOT}"
  cat << 'HANDLER'
#!/usr/bin/env bash
# Read HTTP request
read -r method path _version
headers=""
content_length=0
signature=""
while IFS= read -r line; do
  line="${line%%$'\r'}"
  [ -z "$line" ] && break
  case "${line,,}" in
    content-length:*) content_length="${line#*: }" ;;
    x-hub-signature-256:*) signature="${line#*: }" ;;
  esac
done

# Read body
body=""
if [ "$content_length" -gt 0 ] 2>/dev/null; then
  body=$(head -c "$content_length")
fi

# Validate signature
if [ -n "$_WEBHOOK_SECRET" ]; then
  expected="sha256=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$_WEBHOOK_SECRET" | sed 's/^.* //')"
  if [ "$signature" != "$expected" ]; then
    printf "HTTP/1.1 401 Unauthorized\r\nContent-Length: 12\r\n\r\nUnauthorized"
    exit 0
  fi
fi

# Parse push event
ref=$(printf '%s' "$body" | grep -o '"ref":"[^"]*"' | head -1 | cut -d'"' -f4)
push_branch="${ref#refs/heads/}"

if [ "$push_branch" != "$_WEBHOOK_BRANCH" ]; then
  printf "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nskipped"
  exit 0
fi

# Trigger a poll cycle (reuse the poll logic)
cd "$_WEBHOOK_CLI_ROOT"
source lib/utils.sh 2>/dev/null || true
source lib/cmd_webhook.sh 2>/dev/null || true
_poll_cycle "$_WEBHOOK_CLI_ROOT" "$_WEBHOOK_BRANCH" "" "$_WEBHOOK_CLI_ROOT/.webhook-last-sha" >/dev/null 2>&1 &

printf "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndeployed"
HANDLER
}

# ── Install (systemd service) ─────────────────────────────────────────────────

_webhook_install() {
  local mode="poll"
  local interval=60
  local port=9876

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --mode=*) mode="${1#*=}"; shift ;;
      --interval) interval="$2"; shift 2 ;;
      --interval=*) interval="${1#*=}"; shift ;;
      --port) port="$2"; shift 2 ;;
      --port=*) port="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local strut_bin="$cli_root/strut"
  local user
  user=$(whoami)

  local unit_file="/etc/systemd/system/strut-webhook.service"
  local exec_start

  if [ "$mode" = "poll" ]; then
    exec_start="$strut_bin webhook poll --interval $interval"
  elif [ "$mode" = "serve" ]; then
    exec_start="$strut_bin webhook serve --port $port --secret \${WEBHOOK_SECRET}"
  else
    fail "Unknown mode: $mode (use poll or serve)"
  fi

  echo "[Unit]"
  echo "Description=strut push-to-deploy ($mode)"
  echo "After=network-online.target"
  echo "Wants=network-online.target"
  echo ""
  echo "[Service]"
  echo "Type=simple"
  echo "User=$user"
  echo "WorkingDirectory=$cli_root"
  echo "ExecStart=$exec_start"
  echo "Restart=always"
  echo "RestartSec=10"
  if [ "$mode" = "serve" ]; then
    echo "EnvironmentFile=$cli_root/.webhook.env"
  fi
  echo ""
  echo "[Install]"
  echo "WantedBy=multi-user.target"
  echo ""
  echo "# Save this to: $unit_file"
  echo "# Then: sudo systemctl daemon-reload && sudo systemctl enable --now strut-webhook"
  if [ "$mode" = "serve" ]; then
    echo "# Create $cli_root/.webhook.env with: WEBHOOK_SECRET=<your-secret>"
  fi
}
