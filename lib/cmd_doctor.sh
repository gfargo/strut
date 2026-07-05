#!/usr/bin/env bash
# ==================================================
# cmd_doctor.sh — Diagnostic command handler
# ==================================================
# Comprehensive environment check for strut.
# Runs without a stack — top-level command.
#
# Provides:
#   cmd_doctor [--check-vps [--deep]] [--json] [--fix]

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
      perms=$(stat -c "%a" "$key" 2>/dev/null || stat -f "%Lp" "$key" 2>/dev/null || echo "unknown")
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
    dir_perms=$(stat -c "%a" "$HOME/.ssh" 2>/dev/null || stat -f "%Lp" "$HOME/.ssh" 2>/dev/null || echo "unknown")
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

  # Find all env files. Both `.*env` and `.*.env` globs match `.prod.env`,
  # so dedupe by tracking realpaths we've already added.
  local env_files=() seen=()
  for f in "$cli_root"/.*env "$cli_root"/.*.env; do
    [ -f "$f" ] || continue
    local rp
    rp=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
    local dup=false
    for s in "${seen[@]+"${seen[@]}"}"; do
      [ "$s" = "$rp" ] && { dup=true; break; }
    done
    $dup && continue
    seen+=("$rp")
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

      # Deploy dir, as declared in the probed env file (not the calling process's env).
      local deploy_dir=""
      deploy_dir=$(grep -E  '^VPS_DEPLOY_DIR=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
      deploy_dir="${deploy_dir:-/home/$vps_user/strut}"

      # Run deep preflight against this host when --deep is set.
      if $_DOC_VPS_DEEP; then
        _doc_check_vps_deep "$env_name" "$ssh_opts" "$vps_user" "$vps_host" "$deploy_dir"
      fi

      # Fleet git status — requires fleet_git_status from lib/fleet.sh
      if declare -f fleet_git_status >/dev/null 2>&1; then
        local vps_port="" gh_pat=""
        vps_port=$(grep -E    '^VPS_PORT='       "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
        gh_pat=$(grep -E      '^GH_PAT='         "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
        vps_port="${vps_port:-22}"
        gh_pat="${gh_pat:-${GH_PAT:-}}"

        local branch="${DEFAULT_BRANCH:-main}"
        local fleet_out=""
        fleet_out=$(fleet_git_status "$vps_user" "$vps_host" "$vps_port" "$ssh_key" \
          "$deploy_dir" "$branch" "$gh_pat" 2>/dev/null || true)

        if [ -n "$fleet_out" ]; then
          local f_behind="" f_ahead="" f_dirty="" f_head="" f_working_dir=""
          while IFS= read -r _fline; do
            case "${_fline%%=*}" in
              behind)      f_behind="${_fline#*=}" ;;
              ahead)       f_ahead="${_fline#*=}" ;;
              dirty_count) f_dirty="${_fline#*=}" ;;
              head_sha)    f_head="${_fline#*=}" ;;
              working_dir) f_working_dir="${_fline#*=}" ;;
            esac
          done <<< "$fleet_out"

          local _short_sha="${f_head:0:7}"
          if [ "${f_behind:-?}" = "0" ] && [ "${f_dirty:-0}" = "0" ]; then
            _doc_pass "VPS git ($env_name)" "in sync with origin/$branch (HEAD: $_short_sha)"
          else
            if [ "${f_behind:-?}" != "0" ] && [ "${f_behind:-?}" != "?" ] && [ -n "${f_behind:-}" ]; then
              _doc_warn "VPS git ($env_name)" \
                "$f_behind commit(s) behind origin/$branch — run: strut sync --env ${env_name#.}" \
                "strut sync --env ${env_name#.}"
            fi
            if [ "${f_dirty:-0}" != "0" ] && [ -n "${f_dirty:-}" ]; then
              _doc_warn "VPS dirty ($env_name)" \
                "$f_dirty locally modified file(s) on $vps_host" ""
            fi
          fi

          if [ -n "${f_working_dir:-}" ]; then
            local _expected_prefix="$deploy_dir/stacks/"
            if [[ "$f_working_dir" != "$_expected_prefix"* ]]; then
              _doc_warn "VPS deploy-dir ($env_name)" \
                "containers run from $f_working_dir, expected under ${_expected_prefix%/}" ""
            fi
          fi
        fi
      fi
    else
      _doc_fail "VPS ($env_name)" "cannot reach $vps_host" "Check VPS_HOST in $env_name and SSH key permissions"
    fi
  done
}

# _doc_check_vps_deep <env_name> <ssh_opts> <vps_user> <vps_host> <deploy_dir>
#
# Deep preflight against a VPS: verifies the target is deploy-ready.
# Answers: "Should I run strut against this box?" Each probe runs remotely
# over the same SSH options as the base reachability check.
#
# <deploy_dir> is the VPS_DEPLOY_DIR value parsed from the probed env file
# (falling back to /home/<vps_user>/strut), not the calling process's env.
#
# Checks:
#   docker present + version >= 20
#   docker compose plugin present
#   free disk on / (>= 5GB warn, >= 2GB fail)
#   free memory (>= 1GB warn, >= 512MB fail)
#   ports 80 / 443 not already bound
#   sudo works without prompting (only if VPS_SUDO=true or non-root user)
_doc_check_vps_deep() {
  local env_name="$1" ssh_opts="$2" vps_user="$3" vps_host="$4" deploy_dir="$5"
  local label="VPS-deep ($env_name)"

  # Run all remote probes in a single SSH session for speed.
  # shellcheck disable=SC2086
  local out
  if ! out=$(timeout 20 ssh $ssh_opts "$vps_user@$vps_host" bash -s <<'REMOTE' 2>/dev/null
set -u
echo "=== docker ==="
command -v docker >/dev/null && docker --version 2>/dev/null || echo "docker: NOT_INSTALLED"
echo "=== compose ==="
docker compose version --short 2>/dev/null || echo "compose: NOT_INSTALLED"
echo "=== disk ==="
df -Pk / 2>/dev/null | awk 'NR==2{print $4}'
echo "=== mem ==="
awk '/^MemAvailable:/{print $2; exit} /^MemTotal:/{tot=$2} END{if (tot) print tot}' /proc/meminfo 2>/dev/null
echo "=== ports ==="
ss -tlnH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort -u | tr '\n' ',' 2>/dev/null
echo ""
echo "=== sudo ==="
sudo -n true 2>/dev/null && echo "sudo: PASSWORDLESS" || echo "sudo: NEEDS_PASSWORD"
echo "=== workingdir ==="
docker ps -q 2>/dev/null | head -5 | xargs -r docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null | sort -u | grep -v '^$' || echo "workingdir: EMPTY"
REMOTE
); then
    _doc_fail "$label" "remote probe failed (timeout or SSH error)" ""
    return
  fi

  # ── docker ──
  local docker_line
  docker_line=$(echo "$out" | awk '/^=== docker ===/{flag=1; next} /^===/{flag=0} flag' | head -1)
  if [[ "$docker_line" == *NOT_INSTALLED* ]] || [ -z "$docker_line" ]; then
    _doc_fail "$label / docker" "Docker not installed on VPS" "ssh in and run: curl -fsSL https://get.docker.com | sh"
  else
    # extract N.N.N — parse "Docker version 24.0.7, build ..."
    local dver
    dver=$(echo "$docker_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    local dmajor="${dver%%.*}"
    if [ -n "$dmajor" ] && [ "$dmajor" -ge 20 ] 2>/dev/null; then
      _doc_pass "$label / docker" "$dver"
    else
      _doc_warn "$label / docker" "installed but version $dver (< 20 recommended)" ""
    fi
  fi

  # ── compose ──
  local compose_line
  compose_line=$(echo "$out" | awk '/^=== compose ===/{flag=1; next} /^===/{flag=0} flag' | head -1)
  if [[ "$compose_line" == *NOT_INSTALLED* ]] || [ -z "$compose_line" ]; then
    _doc_fail "$label / compose" "docker compose plugin not installed" "sudo apt install docker-compose-plugin"
  else
    _doc_pass "$label / compose" "$compose_line"
  fi

  # ── disk ── (value in KB)
  local disk_kb
  disk_kb=$(echo "$out" | awk '/^=== disk ===/{flag=1; next} /^===/{flag=0} flag' | head -1 | tr -d ' ')
  if [ -n "$disk_kb" ] && [ "$disk_kb" -gt 0 ] 2>/dev/null; then
    local disk_gb=$((disk_kb / 1024 / 1024))
    if [ "$disk_gb" -ge 5 ]; then
      _doc_pass "$label / disk" "${disk_gb}GB free on /"
    elif [ "$disk_gb" -ge 2 ]; then
      _doc_warn "$label / disk" "only ${disk_gb}GB free on / (recommend >= 5GB)" ""
    else
      _doc_fail "$label / disk" "only ${disk_gb}GB free on / (need >= 2GB)" "Free space before deploying"
    fi
  else
    _doc_warn "$label / disk" "could not determine free disk space" ""
  fi

  # ── memory ── (value in KB)
  local mem_kb
  mem_kb=$(echo "$out" | awk '/^=== mem ===/{flag=1; next} /^===/{flag=0} flag' | head -1 | tr -d ' ')
  if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ] 2>/dev/null; then
    local mem_mb=$((mem_kb / 1024))
    if [ "$mem_mb" -ge 1024 ]; then
      _doc_pass "$label / memory" "${mem_mb}MB available"
    elif [ "$mem_mb" -ge 512 ]; then
      _doc_warn "$label / memory" "only ${mem_mb}MB available (recommend >= 1024MB)" ""
    else
      _doc_fail "$label / memory" "only ${mem_mb}MB available (need >= 512MB)" "Add swap or upgrade instance size"
    fi
  else
    _doc_warn "$label / memory" "could not determine free memory" ""
  fi

  # ── ports ── (comma-separated list of ports currently bound)
  local ports_line
  ports_line=$(echo "$out" | awk '/^=== ports ===/{flag=1; next} /^===/{flag=0} flag' | head -1)
  local port80_bound=false port443_bound=false
  [[ ",${ports_line}," == *,80,* ]] && port80_bound=true
  [[ ",${ports_line}," == *,443,* ]] && port443_bound=true
  if $port80_bound || $port443_bound; then
    local bound=""
    $port80_bound && bound="80"
    $port443_bound && bound="${bound:+$bound, }443"
    _doc_warn "$label / ports" "port(s) $bound already in use (a running web server will conflict)" ""
  else
    _doc_pass "$label / ports" "80 + 443 free"
  fi

  # ── sudo ──
  local sudo_line
  sudo_line=$(echo "$out" | awk '/^=== sudo ===/{flag=1; next} /^===/{flag=0} flag' | head -1)
  if [ "$vps_user" = "root" ]; then
    _doc_pass "$label / sudo" "root (no sudo needed)"
  elif [[ "$sudo_line" == *PASSWORDLESS* ]]; then
    _doc_pass "$label / sudo" "passwordless sudo works"
  else
    _doc_warn "$label / sudo" "sudo requires a password (some strut ops will fail)" "Add '$vps_user ALL=(ALL) NOPASSWD:ALL' to /etc/sudoers.d/"
  fi

  # ── workingdir ── (compose working_dir label from running containers)
  local workingdir_lines
  workingdir_lines=$(echo "$out" | awk '/^=== workingdir ===/{flag=1; next} /^===/{flag=0} flag')
  if [[ "$workingdir_lines" == *"EMPTY"* ]] || [ -z "$workingdir_lines" ]; then
    _doc_pass "$label / workingdir" "no running containers (skip)"
  else
    local expected_prefix
    expected_prefix="$deploy_dir/stacks"
    local mismatch_found=false
    while IFS= read -r wdir; do
      [ -z "$wdir" ] && continue
      if [[ "$wdir" != "$expected_prefix"* ]]; then
        _doc_warn "$label / workingdir" \
          "container working_dir '$wdir' outside expected prefix '$expected_prefix'" \
          "Check VPS_DEPLOY_DIR or re-deploy from the correct checkout"
        mismatch_found=true
      fi
    done <<< "$workingdir_lines"
    if ! $mismatch_found; then
      _doc_pass "$label / workingdir" "all containers under $expected_prefix"
    fi
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

cmd_doctor() {
  local check_vps=false
  _DOC_VPS_DEEP=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --check-vps) check_vps=true; shift ;;
      --deep)      _DOC_VPS_DEEP=true; check_vps=true; shift ;;
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
  echo "Usage: strut doctor [--check-vps] [--deep] [--json] [--fix]"
  echo ""
  echo "Run a comprehensive diagnostic check of your strut environment."
  echo ""
  echo "Flags:"
  echo "  --check-vps    Include VPS connectivity checks (SSH echo to each env file's host)"
  echo "  --deep         Deep VPS preflight — Docker, Compose, disk, memory, ports, sudo"
  echo "                 (implies --check-vps; the 'should I deploy strut here?' wizard)"
  echo "  --json         Output results as JSON"
  echo "  --fix          Show install commands for missing tools"
  echo ""
  echo "Examples:"
  echo "  strut doctor                    # local checks only"
  echo "  strut doctor --fix              # show install hints"
  echo "  strut doctor --check-vps        # + SSH reachability per env"
  echo "  strut doctor --deep             # full preflight against every configured VPS"
  echo "  strut doctor --deep --json      # JSON output for CI / scripting"
  echo ""
}
