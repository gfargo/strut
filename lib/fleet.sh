#!/usr/bin/env bash
# ==================================================
# lib/fleet.sh — Fleet-wide remote git inspection + safe sync
# ==================================================
# Provides remote git status reporting and safe checkout sync for
# multi-host fleets. SSH-backed; requires lib/utils.sh sourced first.
#
# Functions:
#   fleet_git_status_parse  — parse KV output from fleet_git_status (local, testable)
#   fleet_git_status        — SSH into a host and emit git status as KV pairs
#   fleet_sync              — fetch + reset --hard + guarded clean on a remote host
#   fleet_working_dir_check — compare resolved deploy dir to container working_dir label

set -euo pipefail

# fleet_git_status_parse
#
# Reads key=value lines from stdin (as emitted by fleet_git_status) and writes
# shell variable assignments to stdout, suitable for eval:
#
#   eval "$(fleet_git_status ... | fleet_git_status_parse)"
#
# Sets: FLEET_HEAD_SHA, FLEET_BRANCH, FLEET_BEHIND, FLEET_AHEAD,
#       FLEET_DIRTY_COUNT, FLEET_DIRTY_FILES, FLEET_WORKING_DIR
fleet_git_status_parse() {
  local line key val
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      head_sha)    printf 'FLEET_HEAD_SHA=%q\n'    "$val" ;;
      branch)      printf 'FLEET_BRANCH=%q\n'      "$val" ;;
      behind)      printf 'FLEET_BEHIND=%q\n'      "$val" ;;
      ahead)       printf 'FLEET_AHEAD=%q\n'       "$val" ;;
      dirty_count) printf 'FLEET_DIRTY_COUNT=%q\n' "$val" ;;
      dirty_files) printf 'FLEET_DIRTY_FILES=%q\n' "$val" ;;
      working_dir) printf 'FLEET_WORKING_DIR=%q\n' "$val" ;;
    esac
  done
}

# fleet_git_status <user> <host> <port> <ssh_key> <deploy_dir> <branch> [gh_pat]
#
# SSHes into <host> and emits parseable key=value lines describing the git
# state of <deploy_dir>:
#
#   head_sha=<sha>        current HEAD commit
#   branch=<name>         currently checked-out branch
#   behind=<N>            commits HEAD is behind origin/<branch> (? if fetch failed)
#   ahead=<N>             commits HEAD is ahead of origin/<branch>
#   dirty_count=<N>       number of locally modified tracked/untracked files
#   dirty_files=<list>    pipe-separated file paths (max 20)
#   working_dir=<path>    com.docker.compose.project.working_dir label from containers
#
# If gh_pat is empty, fetch falls back to unauthenticated (works for public
# repos or setups using SSH deploy keys). behind/ahead are reported as "?"
# when the fetch fails.
fleet_git_status() {
  local vps_user="$1"
  local vps_host="$2"
  local vps_port="$3"
  local vps_ssh_key="$4"
  local deploy_dir="$5"
  local branch="$6"
  local gh_pat="${7:-}"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Intentional: variables expand locally before SSH
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    if [ ! -d '$deploy_dir' ]; then
      echo 'head_sha=missing'
      echo 'branch=unknown'
      echo 'behind=?'
      echo 'ahead=?'
      echo 'dirty_count=0'
      echo 'dirty_files='
      echo 'working_dir='
      exit 0
    fi
    cd '$deploy_dir'

    head_sha=\$(git rev-parse HEAD 2>/dev/null || echo 'unknown')
    cur_branch=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')

    _fetch_ok=true
    if [ -n '$gh_pat' ]; then
      git \
        -c 'url.https://oauth2:$gh_pat@github.com/.insteadOf=https://github.com/' \
        -c 'url.https://oauth2:$gh_pat@github.com/.insteadOf=git@github.com:' \
        fetch origin 2>/dev/null || _fetch_ok=false
    else
      git fetch origin 2>/dev/null || _fetch_ok=false
    fi

    if \$_fetch_ok; then
      behind=\$(git rev-list --count HEAD..origin/'$branch' 2>/dev/null || echo 0)
      ahead=\$(git rev-list --count origin/'$branch'..HEAD 2>/dev/null || echo 0)
    else
      behind='?'
      ahead='?'
    fi

    dirty_lines=\$(git status --porcelain 2>/dev/null | head -20 || true)
    if [ -n \"\$dirty_lines\" ]; then
      dirty_count=\$(printf '%s\n' \"\$dirty_lines\" | wc -l | tr -d ' ')
      dirty_files=\$(printf '%s\n' \"\$dirty_lines\" | tr '\n' '|' | sed 's/|$//')
    else
      dirty_count=0
      dirty_files=''
    fi

    working_dir=\$(docker ps --format '{{index .Labels \"com.docker.compose.project.working_dir\"}}' 2>/dev/null | grep -v '^\$' | head -1 || true)

    echo \"head_sha=\$head_sha\"
    echo \"branch=\$cur_branch\"
    echo \"behind=\$behind\"
    echo \"ahead=\$ahead\"
    echo \"dirty_count=\$dirty_count\"
    echo \"dirty_files=\$dirty_files\"
    echo \"working_dir=\$working_dir\"
  "
}

# fleet_sync <user> <host> <port> <ssh_key> <deploy_dir> <branch> <gh_pat> [opts]
#
# Brings a remote host's checkout in sync with origin/<branch>:
#   1. git fetch origin  (authenticated via gh_pat when provided)
#   2. git reset --hard origin/<branch>
#   3. git clean -fd  — GUARDED: if untracked non-ignored paths exist, the
#      clean is skipped unless --force-clean is set, preventing accidental
#      deletion of container data directories that live inside the checkout.
#
# Options:
#   --dry-run      Log what would happen; make no remote changes.
#   --force-clean  Remove untracked files even when data dirs are detected.
fleet_sync() {
  local vps_user="$1"
  local vps_host="$2"
  local vps_port="$3"
  local vps_ssh_key="$4"
  local deploy_dir="$5"
  local branch="$6"
  local gh_pat="${7:-}"
  shift 7

  local fleet_dry_run=false force_clean=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)     fleet_dry_run=true;  shift ;;
      --force-clean) force_clean=true; shift ;;
      *)             shift ;;
    esac
  done

  if $fleet_dry_run; then
    log "[DRY-RUN] fleet sync: $vps_user@$vps_host:$deploy_dir → origin/$branch (no changes made)"
    return 0
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  # Intentional: variables expand locally before SSH
  # shellcheck disable=SC2029
  ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    if [ ! -d '$deploy_dir' ]; then
      echo 'ERROR: $deploy_dir not found on VPS' >&2
      exit 1
    fi
    cd '$deploy_dir'

    echo '--- Before sync ---'
    git log --oneline -1

    echo '--- Fetching origin ---'
    if [ -n '$gh_pat' ]; then
      git \\
        -c 'url.https://oauth2:$gh_pat@github.com/.insteadOf=https://github.com/' \\
        -c 'url.https://oauth2:$gh_pat@github.com/.insteadOf=git@github.com:' \\
        fetch origin
    else
      git fetch origin
    fi

    echo '--- Resetting to origin/$branch ---'
    git reset --hard 'origin/$branch'

    # Guard: detect what git clean -fd would remove.
    # Live container data (db volumes, uploads) can live inside the checkout
    # as untracked directories; removing them causes data loss.
    _would_clean=\$(git clean -nd 2>/dev/null || true)
    if [ -n \"\$_would_clean\" ]; then
      if [ '$force_clean' = 'true' ]; then
        echo '--- Cleaning untracked files (--force-clean) ---'
        git clean -fd
      else
        printf 'WARN: Skipping git clean — untracked paths exist that may contain live data:\n' >&2
        printf '%s\n' \"\$_would_clean\" >&2
        printf 'Run strut sync with --force-clean to remove them.\n' >&2
      fi
    else
      git clean -fd
    fi

    echo '--- After sync ---'
    git log --oneline -1
  "
}

# fleet_working_dir_check <deploy_dir> <stack> <container_working_dir>
#
# Returns 0 if <container_working_dir> matches <deploy_dir>/stacks/<stack>,
# or if container_working_dir is empty (no running containers → no check).
# Returns 1 and prints expected/actual lines when they differ.
fleet_working_dir_check() {
  local deploy_dir="$1"
  local stack="$2"
  local container_working_dir="$3"

  [ -z "$container_working_dir" ] && return 0

  local expected_dir="$deploy_dir/stacks/$stack"
  if [ "$container_working_dir" != "$expected_dir" ]; then
    echo "expected=$expected_dir"
    echo "actual=$container_working_dir"
    return 1
  fi
  return 0
}
