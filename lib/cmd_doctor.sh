#!/usr/bin/env bash
# ==================================================
# cmd_doctor.sh — Diagnostic command handler
# ==================================================
# Comprehensive environment check for strut.
# Runs without a stack — top-level command.
#
# Provides:
#   cmd_doctor [--check-vps] [--json] [--fix]

set -euo pipefail

# ── State ─────────────────────────────────────────────────────────────────────
_DOC_PASSED=0
_DOC_WARNED=0
_DOC_FAILED=0
_DOC_JSON_RESULTS="[]"
_DOC_JSON=false
_DOC_FIX=false

_doc_pass() {
  local name="$1" msg="$2"
  _DOC_PASSED=$((_DOC_PASSED + 1))
  if $_DOC_JSON; then
    _DOC_JSON_RESULTS=$(echo "$_DOC_JSON_RESULTS" | jq -c ". += [{\"name\":\"$name\",\"status\":\"pass\",\"message\":\"$msg\"}]")
  else
    echo -e "  ${GREEN}✓${NC} $name: $msg"
  fi
}

_doc_warn() {
  local name="$1" msg="$2" fix="${3:-}"
  _DOC_WARNED=$((_DOC_WARNED + 1))
  if $_DOC_JSON; then
    _DOC_JSON_RESULTS=$(echo "$_DOC_JSON_RESULTS" | jq -c ". += [{\"name\":\"$name\",\"status\":\"warn\",\"message\":\"$msg\",\"fix\":\"$fix\"}]")
  else
    echo -e "  ${YELLOW}⚠${NC} $name: $msg"
    if [ -n "$fix" ] && $_DOC_FIX; then
      echo "    Fix: $fix"
    fi
  fi
}

_doc_fail() {
  local name="$1" msg="$2" fix="${3:-}"
  _DOC_FAILED=$((_DOC_FAILED + 1))
  if $_DOC_JSON; then
    _DOC_JSON_RESULTS=$(echo "$_DOC_JSON_RESULTS" | jq -c ". += [{\"name\":\"$name\",\"status\":\"fail\",\"message\":\"$msg\",\"fix\":\"$fix\"}]")
  else
    echo -e "  ${RED}✗${NC} $name: $msg"
    if [ -n "$fix" ] && $_DOC_FIX; then
      echo "    Fix: $fix"
    fi
  fi
}

# ── Checks ────────────────────────────────────────────────────────────────────

_doc_check_strut_version() {
  local version_file="${STRUT_HOME:-$CLI_ROOT}/VERSION"
  if [ -f "$version_file" ]; then
    local ver
    ver=$(tr -d '[:space:]' < "$version_file")
    _doc_pass "strut" "version $ver"
  else
    _doc_warn "strut" "VERSION file not found" ""
  fi
}

_doc_check_docker() {
  if command -v docker &>/dev/null; then
    if docker info &>/dev/null; then
      local ver
      ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
      _doc_pass "Docker" "running (v$ver)"
    else
      _doc_fail "Docker" "installed but daemon not running" "Start Docker Desktop or: sudo systemctl start docker"
    fi
  else
    _doc_fail "Docker" "not installed" "Install: curl -fsSL https://get.docker.com | bash"
  fi
}

_doc_check_compose() {
  if docker compose version &>/dev/null 2>&1; then
    local ver
    ver=$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    _doc_pass "Docker Compose" "installed (v$ver)"
  else
    _doc_fail "Docker Compose" "not installed" "Install Docker Compose plugin: https://docs.docker.com/compose/install/"
  fi
}

_doc_check_git() {
  if command -v git &>/dev/null; then
    local user
    user=$(git config user.name 2>/dev/null || echo "")
    if [ -n "$user" ]; then
      _doc_pass "Git" "configured (user: $user)"
    else
      _doc_warn "Git" "installed but user.name not set" "git config --global user.name 'Your Name'"
    fi
  else
    _doc_fail "Git" "not installed" "Install: brew install git"
  fi
}

_doc_check_gh() {
  if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null 2>&1; then
      _doc_pass "GitHub CLI" "authenticated"
    else
      _doc_warn "GitHub CLI" "installed but not authenticated" "gh auth login"
    fi
  else
    _doc_warn "GitHub CLI" "not installed (needed for keys, secrets)" "brew install gh"
  fi
}

_doc_check_ssh_key() {
  local found=false
  for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
    if [ -f "$key" ]; then
      _doc_pass "SSH key" "found ($(basename "$key"))"
      found=true

      # Check private key permissions (should be 600 or 400)
      local perms
      perms=$(stat -f "%Lp" "$key" 2>/dev/null || stat -c "%a" "$key" 2>/dev/null || echo "unknown")
      case "$perms" in
        600|400) _doc_pass "SSH key permissions" "$(basename "$key") is $perms" ;;
        unknown) ;; # stat failed, skip
        *) _doc_warn "SSH key permissions" "$(basename "$key") is $perms (should be 600 or 400)" "chmod 600 \"$key\"" ;;
      esac

      break
    fi
  done
  $found || _doc_warn "SSH key" "no default SSH key found in ~/.ssh/" "ssh-keygen -t ed25519"

  # Check ~/.ssh directory permissions (should be 700)
  if [ -d "$HOME/.ssh" ]; then
    local dir_perms
    dir_perms=$(stat -f "%Lp" "$HOME/.ssh" 2>/dev/null || stat -c "%a" "$HOME/.ssh" 2>/dev/null || echo "unknown")
    case "$dir_perms" in
      700) ;; # OK, don't clutter output
      unknown) ;; # stat failed, skip
      *) _doc_warn "SSH directory permissions" "$HOME/.ssh is $dir_perms (should be 700)" "chmod 700 \"$HOME/.ssh\"" ;;
    esac
  fi
}

_doc_check_tool() {
  local name="$1" purpose="$2" install_cmd="$3"
  if command -v "$name" &>/dev/null; then
    _doc_pass "$name" "installed"
  else
    _doc_warn "$name" "not installed ($purpose)" "$install_cmd"
  fi
}

_doc_check_project() {
  local cli_root="${CLI_ROOT:-$(pwd)}"

  # strut.conf
  if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/strut.conf" ]; then
    _doc_pass "strut.conf" "found"
  else
    _doc_warn "strut.conf" "not found (run: strut init)" ""
  fi

  # Stacks
  if [ -d "$cli_root/stacks" ]; then
    local stack_count=0
    local stack_names=""
    for d in "$cli_root/stacks"/*/; do
      [ -d "$d" ] || continue
      local name
      name=$(basename "$d")
      [ "$name" = "shared" ] && continue
      [ -f "$d/docker-compose.yml" ] || continue
      stack_count=$((stack_count + 1))
      [ -n "$stack_names" ] && stack_names="$stack_names, "
      stack_names="$stack_names$name"
    done
    if [ "$stack_count" -gt 0 ]; then
      _doc_pass "Stacks" "$stack_count found ($stack_names)"
    else
      _doc_warn "Stacks" "none found (run: strut scaffold my-app)" ""
    fi
  else
    _doc_warn "Stacks" "stacks/ directory not found" ""
  fi
}

_doc_check_vps() {
  local cli_root="${CLI_ROOT:-$(pwd)}"

  # Find all env files
  local env_files=()
  for f in "$cli_root"/.*env "$cli_root"/.*.env; do
    [ -f "$f" ] || continue
    env_files+=("$f")
  done

  if [ ${#env_files[@]} -eq 0 ]; then
    _doc_warn "VPS" "no env files found" ""
    return
  fi

  for env_file in "${env_files[@]}"; do
    local env_name
    env_name=$(basename "$env_file")
    local vps_host=""

    # Extract VPS_HOST without sourcing the whole file
    vps_host=$(grep -E '^VPS_HOST=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)

    [ -z "$vps_host" ] && continue

    local ssh_key=""
    ssh_key=$(grep -E '^VPS_SSH_KEY=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)

    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
    [ -n "$ssh_key" ] && [ -f "$ssh_key" ] && ssh_opts="$ssh_opts -i $ssh_key"

    local vps_user=""
    vps_user=$(grep -E '^VPS_USER=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
    vps_user="${vps_user:-ubuntu}"

    # shellcheck disable=SC2086
    if timeout 5 ssh $ssh_opts "$vps_user@$vps_host" "echo ok" &>/dev/null; then
      _doc_pass "VPS ($env_name)" "reachable at $vps_host"
    else
      _doc_fail "VPS ($env_name)" "cannot reach $vps_host" "Check VPS_HOST in $env_name and SSH key permissions"
    fi
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────

cmd_doctor() {
  local check_vps=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --check-vps) check_vps=true; shift ;;
      --json)      _DOC_JSON=true; shift ;;
      --fix)       _DOC_FIX=true; shift ;;
      --help|-h)   _usage_doctor; return 0 ;;
      *) shift ;;
    esac
  done

  _DOC_PASSED=0
  _DOC_WARNED=0
  _DOC_FAILED=0
  _DOC_JSON_RESULTS="[]"

  if ! $_DOC_JSON; then
    echo ""
    echo -e "${BLUE}strut Doctor${NC}"
    echo ""
  fi

  # Environment
  _doc_check_strut_version
  _doc_check_docker
  _doc_check_compose
  _doc_check_git
  _doc_check_gh
  _doc_check_ssh_key

  if ! $_DOC_JSON; then echo ""; fi

  # Tools
  _doc_check_tool "jq" "needed for keys, rollback, drift" "brew install jq"
  _doc_check_tool "rsync" "needed for db:pull, db:push" "brew install rsync"
  _doc_check_tool "shellcheck" "needed for development/linting" "brew install shellcheck"
  _doc_check_tool "bats" "needed for running tests" "brew install bats-core"
  _doc_check_tool "sqlite3" "needed for SQLite backup verification" "brew install sqlite"

  if ! $_DOC_JSON; then echo ""; fi

  # Project
  _doc_check_project

  # VPS connectivity (optional)
  if $check_vps; then
    if ! $_DOC_JSON; then echo ""; fi
    _doc_check_vps
  fi

  # Output
  if $_DOC_JSON; then
    jq -n \
      --argjson checks "$_DOC_JSON_RESULTS" \
      --arg passed "$_DOC_PASSED" \
      --arg warned "$_DOC_WARNED" \
      --arg failed "$_DOC_FAILED" \
      '{
        checks: $checks,
        summary: {
          passed: ($passed | tonumber),
          warnings: ($warned | tonumber),
          errors: ($failed | tonumber)
        }
      }'
  else
    echo ""
    if [ $_DOC_FAILED -gt 0 ]; then
      echo -e "${RED}$_DOC_PASSED passed, $_DOC_WARNED warning(s), $_DOC_FAILED error(s)${NC}"
    elif [ $_DOC_WARNED -gt 0 ]; then
      echo -e "${GREEN}$_DOC_PASSED passed${NC}, ${YELLOW}$_DOC_WARNED warning(s)${NC}"
    else
      echo -e "${GREEN}$_DOC_PASSED passed — all good${NC}"
    fi
    echo ""
  fi

  [ $_DOC_FAILED -eq 0 ]
}

_usage_doctor() {
  echo ""
  echo "Usage: strut doctor [--check-vps] [--json] [--fix]"
  echo ""
  echo "Run a comprehensive diagnostic check of your strut environment."
  echo ""
  echo "Flags:"
  echo "  --check-vps    Include VPS connectivity checks (slower)"
  echo "  --json         Output results as JSON"
  echo "  --fix          Show install commands for missing tools"
  echo ""
  echo "Examples:"
  echo "  strut doctor"
  echo "  strut doctor --fix"
  echo "  strut doctor --check-vps"
  echo "  strut doctor --json"
  echo ""
}
