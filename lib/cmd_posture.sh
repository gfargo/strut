#!/usr/bin/env bash
# ==================================================
# lib/cmd_posture.sh — Security / ops posture audit
# ==================================================
# `strut posture [--stack <name>] [--category <cat>] [--fail-on <level>] [--json]`
#
# Runs a battery of security and operational checks across every stack and
# reports pass/warn/fail for each. Designed as a CI gate — `--fail-on warn`
# lets CI block on a warning threshold.
#
# Scope note: the existing `strut audit` command performs VPS discovery for
# migration workflows (see lib/audit.sh). This is a separate posture check
# to avoid breaking that command's positional-arg interface.

set -euo pipefail

# ── Result buffers ────────────────────────────────────────────────────────────
# Each finding is stored as TSV: level<TAB>category<TAB>stack<TAB>message<TAB>remediation
_POSTURE_RESULTS=()
_POSTURE_PASS=0
_POSTURE_WARN=0
_POSTURE_FAIL=0

posture_reset() {
  _POSTURE_RESULTS=()
  _POSTURE_PASS=0
  _POSTURE_WARN=0
  _POSTURE_FAIL=0
}

# posture_emit <level> <category> <stack> <message> [remediation]
posture_emit() {
  local level="$1"
  local category="$2"
  local stack="$3"
  local msg="$4"
  local remedy="${5:-}"
  local IFS=$'\t'
  _POSTURE_RESULTS+=("$level	$category	$stack	$msg	$remedy")
  case "$level" in
    pass) _POSTURE_PASS=$((_POSTURE_PASS + 1)) ;;
    warn) _POSTURE_WARN=$((_POSTURE_WARN + 1)) ;;
    fail) _POSTURE_FAIL=$((_POSTURE_FAIL + 1)) ;;
  esac
}

# ── Individual checks ─────────────────────────────────────────────────────────

# Placeholder tokens that suggest the operator forgot to set a real value
_POSTURE_PLACEHOLDERS_REGEX='^(changeme|change_me|password|todo|xxx+|placeholder|secret|admin|root)$'

# check_placeholder_secrets <stack>
#
# Scans env files for values that look like placeholders. The env file lives
# outside the stack dir (at CLI_ROOT/.env or CLI_ROOT/.<env>.env) so we scan
# all strut-managed env files, attributing findings to whichever stacks use
# them (every stack, since env files are shared).
check_placeholder_secrets() {
  local stack="$1"
  local env_file
  for env_file in "$CLI_ROOT"/.env "$CLI_ROOT"/.*.env; do
    [ -f "$env_file" ] || continue
    local env_base
    env_base=$(basename "$env_file")
    local line key val
    while IFS= read -r line; do
      # Skip blanks and comments
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" == *"="* ]] || continue
      key="${line%%=*}"
      val="${line#*=}"
      # Strip surrounding quotes
      val="${val#\"}"; val="${val%\"}"
      val="${val#\'}"; val="${val%\'}"
      # Lowercase for comparison
      local lower
      lower=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
      if [[ "$lower" =~ $_POSTURE_PLACEHOLDERS_REGEX ]]; then
        posture_emit "fail" "secrets" "$stack" \
          "$env_base: $key appears to be a placeholder ('$val')" \
          "Set a real value for $key in $env_file"
        return 0
      fi
    done < "$env_file"
  done
  posture_emit "pass" "secrets" "$stack" "no placeholder values in env files"
}

# check_env_in_git <stack>
#
# Warns if any .env* file is tracked by git — env files routinely contain
# secrets and should be gitignored.
check_env_in_git() {
  local stack="$1"
  command -v git >/dev/null 2>&1 || { posture_emit "pass" "filesystem" "$stack" "git not available; skipping env-in-git check"; return; }
  [ -d "$CLI_ROOT/.git" ] || { posture_emit "pass" "filesystem" "$stack" "not a git repo; skipping env-in-git check"; return; }

  local tracked
  tracked=$(cd "$CLI_ROOT" && git ls-files '.env' '.*.env' '*.env' 2>/dev/null || true)
  if [ -n "$tracked" ]; then
    local first
    first=$(echo "$tracked" | head -1)
    posture_emit "fail" "filesystem" "$stack" \
      ".env file tracked by git: $first" \
      "Add env files to .gitignore and run 'git rm --cached' on them"
  else
    posture_emit "pass" "filesystem" "$stack" "no env files tracked by git"
  fi
}

# check_compose_ports <stack>
#
# Warns about services publishing to 0.0.0.0 when they could be internal.
# The check is heuristic — we flag unprefixed `<port>:<port>` or explicit
# `0.0.0.0:<port>:<port>` mappings. We pass if ports are bound to 127.0.0.1
# or only `expose:` is used.
check_compose_ports() {
  local stack="$1"
  local compose="$CLI_ROOT/stacks/$stack/docker-compose.yml"
  [ -f "$compose" ] || { posture_emit "pass" "network" "$stack" "no docker-compose.yml"; return; }

  local exposed
  exposed=$(grep -En '^\s*-\s*"?(0\.0\.0\.0:)?[0-9]+:[0-9]+' "$compose" 2>/dev/null | \
            grep -vE '127\.0\.0\.1:' || true)

  if [ -n "$exposed" ]; then
    local count
    count=$(echo "$exposed" | wc -l | tr -d ' ')
    local first_line
    first_line=$(echo "$exposed" | head -1 | sed 's/^[[:space:]]*//')
    posture_emit "warn" "network" "$stack" \
      "$count port mapping(s) publish to 0.0.0.0 (first: $first_line)" \
      "Prefix with 127.0.0.1: to restrict to localhost or move behind the reverse proxy"
  else
    posture_emit "pass" "network" "$stack" "no unrestricted port mappings"
  fi
}

# check_resource_limits <stack>
#
# Warns if docker-compose services define no memory limit. Unbounded
# services can starve the host on runaway growth.
check_resource_limits() {
  local stack="$1"
  local compose="$CLI_ROOT/stacks/$stack/docker-compose.yml"
  [ -f "$compose" ] || { posture_emit "pass" "runtime" "$stack" "no docker-compose.yml"; return; }

  # Count services (crude but good enough for a warning signal)
  local service_count
  service_count=$(awk '/^services:/{in_services=1;next} /^[a-zA-Z]/{in_services=0} in_services && /^  [a-zA-Z][a-zA-Z0-9_-]*:/{n++} END{print n+0}' "$compose")

  local limit_count
  limit_count=$(grep -cE '^\s*(mem_limit|limits:)' "$compose" 2>/dev/null || echo 0)
  # Strip any trailing whitespace/newlines from grep output
  limit_count=$(printf '%s' "$limit_count" | tr -d '[:space:]')

  if [ "$service_count" -eq 0 ]; then
    posture_emit "pass" "runtime" "$stack" "no services in docker-compose.yml"
  elif [ "$limit_count" -eq 0 ]; then
    posture_emit "warn" "runtime" "$stack" \
      "$service_count service(s) with no memory limits" \
      "Set mem_limit or deploy.resources.limits in docker-compose.yml"
  else
    posture_emit "pass" "runtime" "$stack" "resource limits defined"
  fi
}

# check_required_vars <stack>
#
# Reads stacks/<stack>/required_vars and verifies each listed variable is
# defined and non-empty in the env file.
check_required_vars() {
  local stack="$1"
  local req_file="$CLI_ROOT/stacks/$stack/required_vars"
  [ -f "$req_file" ] || { posture_emit "pass" "secrets" "$stack" "no required_vars declared"; return; }

  # Use whichever env file is most likely to be loaded
  local env_file="$CLI_ROOT/.env"
  [ -f "$env_file" ] || env_file=""

  if [ -z "$env_file" ]; then
    posture_emit "warn" "secrets" "$stack" \
      "required_vars declared but no .env file to validate against" \
      "Create $CLI_ROOT/.env or run 'strut init'"
    return
  fi

  local missing=()
  local var
  while IFS= read -r var; do
    # Skip blanks/comments
    [[ -z "$var" || "$var" =~ ^# ]] && continue
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    [ -z "$var" ] && continue
    if ! grep -qE "^${var}=.+" "$env_file" 2>/dev/null; then
      missing+=("$var")
    fi
  done < <(preprocess_config "$req_file")

  if [ "${#missing[@]}" -gt 0 ]; then
    local first="${missing[0]}"
    local count="${#missing[@]}"
    posture_emit "fail" "secrets" "$stack" \
      "$count required var(s) missing or empty (first: $first)" \
      "Set missing vars in $env_file"
  else
    posture_emit "pass" "secrets" "$stack" "all required vars present"
  fi
}

# ── Category dispatch ─────────────────────────────────────────────────────────

# run_category <stack> <category>
#
# Runs checks in the given category. `all` runs everything.
run_category() {
  local stack="$1"
  local category="$2"

  case "$category" in
    secrets|all)
      check_placeholder_secrets "$stack"
      check_required_vars "$stack"
      ;;
  esac
  case "$category" in
    filesystem|all)
      check_env_in_git "$stack"
      ;;
  esac
  case "$category" in
    network|all)
      check_compose_ports "$stack"
      ;;
  esac
  case "$category" in
    runtime|all)
      check_resource_limits "$stack"
      ;;
  esac

  case "$category" in
    secrets|filesystem|network|runtime|all) ;;
    *) fail "Unknown category: $category (secrets|filesystem|network|runtime|all)"; return 1 ;;
  esac
}

# ── Output ────────────────────────────────────────────────────────────────────

_posture_level_glyph() {
  case "$1" in
    pass) echo -e "${GREEN}✓${NC}" ;;
    warn) echo -e "${YELLOW}⚠${NC}" ;;
    fail) echo -e "${RED}✗${NC}" ;;
    *)    echo "?" ;;
  esac
}

# _posture_render_text — print findings in human-readable format
_posture_render_text() {
  echo ""
  echo -e "${BLUE}Posture check${NC}"
  echo ""
  local line level category stack msg remedy
  for line in "${_POSTURE_RESULTS[@]+"${_POSTURE_RESULTS[@]}"}"; do
    IFS=$'\t' read -r level category stack msg remedy <<<"$line"
    # Skip passes in text mode to keep the report focused on actionable items
    [ "$level" = "pass" ] && continue
    local glyph
    glyph=$(_posture_level_glyph "$level")
    echo -e "  $glyph [$category] $stack: $msg"
    [ -n "$remedy" ] && echo -e "      ${BLUE}→${NC} $remedy"
  done
  echo ""
  echo "$_POSTURE_PASS passed, $_POSTURE_WARN warnings, $_POSTURE_FAIL failures"
  echo ""
}

_posture_render_json() {
  OUTPUT_MODE=json
  out_json_object
    out_json_field "timestamp" "$(date -u +%FT%TZ)"
    out_json_array "findings"
      local line level category stack msg remedy
      for line in "${_POSTURE_RESULTS[@]+"${_POSTURE_RESULTS[@]}"}"; do
        IFS=$'\t' read -r level category stack msg remedy <<<"$line"
        out_json_object
          out_json_field "level" "$level"
          out_json_field "category" "$category"
          out_json_field "stack" "$stack"
          out_json_field "message" "$msg"
          out_json_field "remediation" "$remedy"
        out_json_close_object
      done
    out_json_close_array
    out_json_field_raw "summary" "{\"pass\":$_POSTURE_PASS,\"warn\":$_POSTURE_WARN,\"fail\":$_POSTURE_FAIL}"
  out_json_close_object
  out_json_newline
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

cmd_posture() {
  local stack_filter=""
  local category="all"
  local fail_on="fail"
  local json_mode="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack=*)    stack_filter="${1#*=}"; shift ;;
      --stack)      stack_filter="${2:-}"; shift 2 ;;
      --category=*) category="${1#*=}"; shift ;;
      --category)   category="${2:-}"; shift 2 ;;
      --fail-on=*)  fail_on="${1#*=}"; shift ;;
      --fail-on)    fail_on="${2:-}"; shift 2 ;;
      --json)       json_mode="true"; shift ;;
      --help|-h)
        cat <<'EOF'
Usage: strut posture [options]

Security and ops posture check. Scans every stack (or one, with --stack)
for placeholder secrets, exposed ports, missing resource limits, env
files tracked in git, and missing required_vars.

Options:
  --stack <name>        Limit to a single stack
  --category <cat>      secrets | filesystem | network | runtime | all  (default: all)
  --fail-on <level>     fail | warn    Exit 1 threshold (default: fail)
  --json                Structured JSON output for CI
EOF
        return 0
        ;;
      *) fail "Unknown flag: $1"; return 1 ;;
    esac
  done

  case "$fail_on" in
    fail|warn) ;;
    *) fail "Invalid --fail-on level: $fail_on (fail|warn)"; return 1 ;;
  esac

  [ -d "$CLI_ROOT/stacks" ] || { fail "No stacks/ directory found — run 'strut init' to get started"; return 1; }

  posture_reset

  local stack_dir name
  for stack_dir in "$CLI_ROOT/stacks"/*/; do
    [ -d "$stack_dir" ] || continue
    name=$(basename "$stack_dir")
    [ "$name" = "shared" ] && continue
    [ -n "$stack_filter" ] && [ "$name" != "$stack_filter" ] && continue
    run_category "$name" "$category" || return 1
  done

  if [ "$json_mode" = "true" ]; then
    _posture_render_json
  else
    _posture_render_text
  fi

  # Exit code based on --fail-on
  if [ "$_POSTURE_FAIL" -gt 0 ]; then
    return 1
  fi
  if [ "$fail_on" = "warn" ] && [ "$_POSTURE_WARN" -gt 0 ]; then
    return 1
  fi
  return 0
}
