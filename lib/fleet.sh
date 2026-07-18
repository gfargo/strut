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

# remote_ssh_with_pat <ssh_opts> <target> <gh_pat> <remote_script>
#
# Runs <remote_script> on <target> over ssh, with git PAT auth wired up
# without ever putting the token on any argv (local ssh argv, remote shell
# argv, or git argv). If gh_pat is non-empty, the token travels over ssh's
# stdin, gets written remotely to a mode-600 temp file consumed by git's
# credential.helper, and is removed via a remote `trap ... EXIT` regardless
# of outcome. If gh_pat is empty, <remote_script> runs as-is (no credential
# setup, git falls back to whatever auth is already configured on the host).
#
# Inside <remote_script>, invoke `git_cred` (a remote shell function this
# function defines) in place of `git` wherever the operation needs auth,
# e.g.: git_cred fetch origin
#
# git_cred wraps `git -c "credential.helper=store --file=$_cred_file" "$@"`
# with the value double-quoted inside the function body — NOT exposed as a
# plain variable callers interpolate unquoted. An earlier version handed
# callers a $GIT_CRED_OPT string containing both the `-c` flag and its
# (space-containing) value; unquoted at the call site, the remote shell
# word-split it into separate argv tokens and `--file=...` landed as an
# invalid top-level git flag instead of staying part of the -c value (#429).
remote_ssh_with_pat() {
  local ssh_opts="$1"
  local target="$2"
  local gh_pat="$3"
  local remote_script="$4"

  if [ -n "$gh_pat" ]; then
    # shellcheck disable=SC2016 # intentional: these expand on the remote shell, not here
    local prelude='
      umask 077
      _cred_file=$(mktemp "${HOME}/.strut-git-cred-XXXXXX") || exit 1
      trap '"'"'rm -f "$_cred_file"'"'"' EXIT
      IFS= read -r _cred_line
      printf "%s\n" "$_cred_line" > "$_cred_file"
      git_cred() { git -c "credential.helper=store --file=$_cred_file" "$@"; }
    '
    # shellcheck disable=SC2029
    printf 'https://oauth2:%s@github.com\n' "$gh_pat" | ssh $ssh_opts "$target" "$prelude
$remote_script"
  else
    # shellcheck disable=SC2016 # intentional: expands on the remote shell
    ssh $ssh_opts "$target" 'git_cred() { git "$@"; }
'"$remote_script"
  fi
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

  # Intentional: variables (other than the PAT, which never touches this
  # string — see remote_ssh_with_pat) expand locally before SSH
  local remote_script="
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
    git_cred fetch origin 2>/dev/null || _fetch_ok=false

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

  remote_ssh_with_pat "$ssh_opts" "$vps_user@$vps_host" "$gh_pat" "$remote_script"
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

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  if $fleet_dry_run; then
    log "[DRY-RUN] fleet sync: $vps_user@$vps_host:$deploy_dir → origin/$branch (no changes made)"
    # git clean -nd is itself non-destructive, so dry-run can show a real
    # preview of what the guarded clean step would remove, not just a
    # description — the one destructive step in an otherwise reversible sync.
    local _clean_preview
    # shellcheck disable=SC2029
    _clean_preview=$(ssh $ssh_opts "$vps_user@$vps_host" "cd '$deploy_dir' 2>/dev/null && git clean -nd 2>/dev/null") || _clean_preview=""
    if [ -n "$_clean_preview" ]; then
      warn "git clean -fd would remove the following untracked paths (skipped unless --force-clean):"
      echo "$_clean_preview"
    else
      log "git clean -fd would remove nothing (no untracked paths, or host unreachable)"
    fi
    return 0
  fi

  # Intentional: variables (other than the PAT, which never touches this
  # string — see remote_ssh_with_pat) expand locally before SSH
  local remote_script="
    set -e
    if [ ! -d '$deploy_dir' ]; then
      echo 'ERROR: $deploy_dir not found on VPS' >&2
      exit 1
    fi
    if [ ! -d '$deploy_dir/.git' ]; then
      echo 'ERROR: $deploy_dir exists but is not a git checkout (no .git found)' >&2
      echo 'This host was likely provisioned by rsync or another non-strut path.' >&2
      echo 'Run: strut <stack> remote:init --env <env> to clone a proper checkout here.' >&2
      exit 1
    fi
    cd '$deploy_dir'

    echo '--- Before sync ---'
    git log --oneline -1

    echo '--- Fetching origin ---'
    git_cred fetch origin

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

  remote_ssh_with_pat "$ssh_opts" "$vps_user@$vps_host" "$gh_pat" "$remote_script"
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
