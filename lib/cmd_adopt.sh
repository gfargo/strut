#!/usr/bin/env bash
# ==================================================
# cmd_adopt.sh — Non-destructively adopt a hand-deployed stack
# ==================================================
# Usage: strut <stack> adopt --host <h> [options]
#
# Brings a stack that was `docker compose up`'d by hand on a VPS under
# strut's management, without ever running a git operation against the
# directory holding its live data. Rather than attempting git surgery on
# that directory in place, adopt clones a FRESH, separate strut checkout —
# git only ever touches the new, empty-by-construction directory. Data
# continuity is handled by clear printed guidance, not by strut moving
# anything on a live host itself.
#
# See lib/deploy_blue_green.sh's `.bluegreen` state file for the precedent
# this follows for per-stack state tracking (flat key=value, not JSON).
# ==================================================

set -euo pipefail

_usage_adopt() {
  echo "Usage: strut <stack> adopt --host <h> [options]"
  echo ""
  echo "Non-destructively bring a hand-deployed stack under strut's management."
  echo "Never runs git clean/reset against the directory holding live data —"
  echo "clones a fresh, separate strut checkout instead, and guides you through"
  echo "reconciling config and data manually."
  echo ""
  echo "Options:"
  echo "  --host <h>              VPS hostname or IP (required, or set VPS_HOST)"
  echo "  --user <u>              SSH user (default: ubuntu)"
  echo "  --key <path>            SSH key path"
  echo "  --port <p>              SSH port (default: 22)"
  echo "  --env <name>            Environment name (default: prod)"
  echo "  --remote-dir <path>     Explicit path to the live compose project"
  echo "                          (skips auto-discovery; required if discovery"
  echo "                          finds zero or more than one matching project)"
  echo "  --remote-compose-file <p>  Explicit path to the live compose file"
  echo "                          (default: <remote-dir>/docker-compose.yml)"
  echo "  --remote-env-file <p>   Explicit path to the live .env file"
  echo "                          (default: <remote-dir>/.env)"
  echo "  --repo <url>            Git repository URL (default: local git remote)"
  echo "  --branch <name>         Branch to checkout (default: main)"
  echo "  --deploy-dir <path>     Where to clone the fresh checkout (default:"
  echo "                          resolve_deploy_dir's usual convention)"
  echo "  --dry-run               Show what would happen without making changes"
  echo "  --force                 Proceed even if the committed compose file"
  echo "                          doesn't match what's running, or overwrite an"
  echo "                          existing local env file"
  echo ""
  echo "Examples:"
  echo "  strut my-app adopt --host compass.local --user gfargo --env prod"
  echo "  strut my-app adopt --host 10.0.0.5 --remote-dir /opt/myapp --env prod"
  echo ""
  echo "What this does:"
  echo "  1. Discovers the live compose project (or uses --remote-dir)"
  echo "  2. Verifies the committed compose file matches what's actually running"
  echo "  3. Reports any data/volumes living inside the checkout (never moves them)"
  echo "  4. Clones a fresh, separate strut checkout — never touches the live dir"
  echo "  5. Pulls the live .env into tracked, encrypted config"
  echo "  6. Marks the stack as strut-managed and confirms the new checkout is clean"
}

# _adopt_shell_quote <string>
#
# Safely single-quotes an arbitrary string for embedding in a remote command
# string sent over ssh — closes the quote, escapes any embedded single quote
# as '\'', reopens it. Required for every value that isn't a static literal,
# especially host paths parsed out of a remote/committed docker-compose.yml:
# an attacker-controlled compose file is otherwise a command-injection vector
# (a bind-mount path like "./data'; rm -rf /; '" breaks naive '$var'
# interpolation).
_adopt_shell_quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# ── Discovery ────────────────────────────────────────────────────────────────

ADOPT_DISCOVERED_WORKING_DIR=""
ADOPT_DISCOVERED_PROJECT_NAME=""

# _adopt_discover <ssh_opts> <user> <host> <stack> <env_name>
#
# Looks for a running compose project whose name matches strut's own naming
# convention for this stack — bare <stack>, or <stack>-<env_name> (mirrors
# resolve_compose_cmd's project naming in lib/utils.sh). Exactly one match
# sets ADOPT_DISCOVERED_WORKING_DIR/ADOPT_DISCOVERED_PROJECT_NAME and returns
# 0; zero matches return 1 so the caller can fall back to --remote-dir
# instead of guessing among ambiguous candidates.
_adopt_discover() {
  local ssh_opts="$1" user="$2" host="$3" stack="$4" env_name="$5"
  ADOPT_DISCOVERED_WORKING_DIR=""
  ADOPT_DISCOVERED_PROJECT_NAME=""

  local cand cand_q found_ids=""
  for cand in "$stack" "${stack}-${env_name}"; do
    cand_q=$(_adopt_shell_quote "$cand")
    # shellcheck disable=SC2029
    local ids
    ids=$(ssh $ssh_opts "$user@$host" "docker ps -q --filter label=com.docker.compose.project=$cand_q" 2>/dev/null) || ids=""
    if [ -n "$ids" ]; then
      found_ids="$ids"
      ADOPT_DISCOVERED_PROJECT_NAME="$cand"
      break
    fi
  done

  [ -n "$found_ids" ] || return 1

  local first_id first_id_q
  first_id=$(echo "$found_ids" | head -1)
  first_id_q=$(_adopt_shell_quote "$first_id")
  # shellcheck disable=SC2029
  ADOPT_DISCOVERED_WORKING_DIR=$(ssh $ssh_opts "$user@$host" "docker inspect $first_id_q --format '{{ index .Config.Labels \"com.docker.compose.project.working_dir\" }}'" 2>/dev/null) || ADOPT_DISCOVERED_WORKING_DIR=""

  [ -n "$ADOPT_DISCOVERED_WORKING_DIR" ] || return 1
  return 0
}

# _adopt_project_name_at <ssh_opts> <user> <host> <remote_dir>
#
# Best-effort: echoes the compose project name of whatever's running at
# <remote_dir>, or empty if nothing matches. Used only for display/guidance
# text when --remote-dir was given explicitly (discovery is skipped).
_adopt_project_name_at() {
  local ssh_opts="$1" user="$2" host="$3" remote_dir="$4"
  local remote_dir_q
  remote_dir_q=$(_adopt_shell_quote "$remote_dir")
  # shellcheck disable=SC2029
  ssh $ssh_opts "$user@$host" "docker ps -q --filter label=com.docker.compose.project.working_dir=$remote_dir_q | head -1 | xargs -r docker inspect --format '{{ index .Config.Labels \"com.docker.compose.project\" }}'" 2>/dev/null || echo ""
}

# _adopt_fetch_remote_file <ssh_opts> <user> <host> <path>
# Plain remote cat — deliberately not diff_fetch_remote (lib/diff.sh), which
# reads VPS_HOST/VPS_USER/etc from global env rather than params; adopt's
# target host/user come from --host/--user flags and may not match whatever
# (if anything) is currently exported.
_adopt_fetch_remote_file() {
  local ssh_opts="$1" user="$2" host="$3" path="$4"
  local path_q
  path_q=$(_adopt_shell_quote "$path")
  # shellcheck disable=SC2029
  ssh $ssh_opts "$user@$host" "cat $path_q 2>/dev/null" 2>/dev/null || echo ""
}

# ── Phase 2: verify compose matches ─────────────────────────────────────────

# _adopt_verify_compose <ssh_opts> <user> <host> <remote_compose_path> <local_compose_file>
#
# Diffs the committed compose file against whatever's actually running.
# Prints the diff on mismatch. Returns 0 if they match (or the remote file
# couldn't be read at all — nothing to compare, warn and continue), 1 if
# they differ (caller decides whether --force allows proceeding anyway).
_adopt_verify_compose() {
  local ssh_opts="$1" user="$2" host="$3" remote_compose_path="$4" local_compose="$5"

  local remote_content
  remote_content=$(_adopt_fetch_remote_file "$ssh_opts" "$user" "$host" "$remote_compose_path")

  if [ -z "$remote_content" ]; then
    warn "Could not read $remote_compose_path on the remote — skipping compose verification."
    return 0
  fi

  local local_content
  local_content=$(cat "$local_compose")

  if [ "$remote_content" = "$local_content" ]; then
    ok "Committed compose file matches what's running"
    return 0
  fi

  warn "Committed compose file differs from what's actually running:"
  diff -u <(echo "$remote_content") <(echo "$local_content") | sed -n '3,60p' || true
  return 1
}

# ── Phase 3: detect data-at-risk (report only, never mutates) ──────────────

# _adopt_detect_data <ssh_opts> <user> <host> <live_dir> <compose_file> <stack> <deploy_dir>
#
# Reports untracked data paths a compose file's bind mounts reference, so the
# operator knows what to relocate before trusting strut to manage this
# stack's volumes going forward. Resolves ${VAR:-default} host-path prefixes
# to their default when present; flags anything without a default as
# "depends on $VAR, check manually." Distinguishes bind mounts from named
# volumes via diff_extract_named_volumes (lib/diff.sh) — a bare "name:" match
# against a top-level volumes: key is Docker-managed, not filesystem data
# living inside the checkout. Never touches the filesystem itself.
#
# The volumes: sub-block is located by indentation RELATIVE to wherever
# "volumes:" itself is found (not a hardcoded column), so this tolerates
# both 2-space and 4-space compose files. Long-form/mapping-style volume
# entries (e.g. "- type: bind") can't be reduced to a host path by this
# parser — rather than silently missing them, each one prints "__UNPARSED__"
# so the caller surfaces a manual-review warning instead of a false "clean."
_adopt_detect_data() {
  local ssh_opts="$1" user="$2" host="$3" live_dir="$4" compose_file="$5" stack="$6" deploy_dir="$7"

  local content
  content=$(cat "$compose_file")

  local named_volumes
  named_volumes=$(diff_extract_named_volumes "$content")

  local candidates
  candidates=$(echo "$content" | awk '
    BEGIN { in_services = 0; in_vol_block = 0; vol_indent = -1 }
    /^services:[[:space:]]*$/ { in_services = 1; next }
    /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {
      if ($0 !~ /^services:/) { in_services = 0; in_vol_block = 0 }
    }
    in_services && /^[[:space:]]+volumes:[[:space:]]*$/ {
      match($0, /^[[:space:]]*/)
      vol_indent = RLENGTH
      in_vol_block = 1
      next
    }
    in_services && in_vol_block {
      match($0, /^[[:space:]]*/)
      cur_indent = RLENGTH
      if (cur_indent <= vol_indent) {
        in_vol_block = 0
      } else if ($0 ~ /^[[:space:]]*-[[:space:]]/) {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        if (line ~ /^\$\{[^}]*\}/) {
          match(line, /^\$\{[^}]*\}/)
          print substr(line, RSTART, RLENGTH)
        } else if (line ~ /^[^[:space:]]+:[[:space:]]/ || line !~ /:/) {
          # "key: value" mapping form (long-form volume) or no colon at all —
          # not a short-form HOST:CONTAINER pair we can extract a path from.
          print "__UNPARSED__"
        } else {
          n = split(line, parts, ":")
          print parts[1]
        }
      }
    }
  ')

  if [ -z "$candidates" ]; then
    log "No bind-mount volumes found in the compose file."
    return 0
  fi

  local found_any=false
  local host_part resolved is_named nv abs_path abs_path_q dest_q
  while IFS= read -r host_part; do
    [ -n "$host_part" ] || continue

    if [ "$host_part" = "__UNPARSED__" ]; then
      found_any=true
      warn "  Found a volume entry this parser couldn't fully interpret (long-form/mapping syntax, or unrecognized structure) — inspect docker-compose.yml manually before considering this stack clean to adopt."
      continue
    fi

    resolved="$host_part"
    if [[ "$host_part" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:-(.*)\}$ ]]; then
      resolved="${BASH_REMATCH[1]}"
    elif [[ "$host_part" =~ ^\$\{?[A-Za-z_] ]]; then
      warn "  Bind mount host path depends on an env var with no default ($host_part) — check its value in the live .env manually once pulled."
      continue
    fi

    is_named=false
    while IFS= read -r nv; do
      [ -n "$nv" ] && [ "$resolved" = "$nv" ] && { is_named=true; break; }
    done <<< "$named_volumes"
    [ "$is_named" = "true" ] && continue

    case "$resolved" in
      /*|./*|../*) ;;
      *) continue ;;
    esac

    resolved="${resolved#./}"
    abs_path="$resolved"
    [[ "$resolved" == /* ]] || abs_path="$live_dir/$resolved"
    abs_path_q=$(_adopt_shell_quote "$abs_path")

    # shellcheck disable=SC2029
    if ssh $ssh_opts "$user@$host" "test -d $abs_path_q" 2>/dev/null; then
      found_any=true
      warn "  Data directory lives inside the checkout: $abs_path"
      echo "    Once the fresh checkout exists, relocate it there manually:"
      dest_q=$(_adopt_shell_quote "$deploy_dir/stacks/$stack/$resolved")
      echo "      ssh $user@$host \"mv $abs_path_q $dest_q\""
    fi
  done <<< "$candidates"

  [ "$found_any" = "true" ] || log "No live data directories found inside the checkout — clean to adopt."
}

# ── Phase 4: bootstrap a fresh, separate strut checkout ─────────────────────

# _adopt_bootstrap_checkout <ssh_opts> <user> <host> <port> <ssh_key> <repo_url> <branch> <deploy_dir>
#
# Clones fresh into <deploy_dir> — reuses remote:init's exact clone logic
# (lib/cmd_remote_init.sh). Idempotent: if a checkout already exists there
# (e.g. a previous adopt attempt got this far), reuses it rather than
# re-cloning into a non-empty directory.
_adopt_bootstrap_checkout() {
  local ssh_opts="$1" user="$2" host="$3" port="$4" ssh_key="$5" repo_url="$6" branch="$7" deploy_dir="$8"

  local deploy_dir_q branch_q
  deploy_dir_q=$(_adopt_shell_quote "$deploy_dir")
  branch_q=$(_adopt_shell_quote "$branch")

  # shellcheck disable=SC2029
  if ssh $ssh_opts "$user@$host" "test -d ${deploy_dir_q}/.git" 2>/dev/null; then
    ok "Strut checkout already exists at $deploy_dir (from a previous adopt attempt) — reusing it"
  else
    local gh_pat="${GH_PAT:-}"
    if [ -n "$gh_pat" ]; then
      local clone_url="$repo_url" clone_url_q
      if echo "$clone_url" | grep -q "^git@"; then
        clone_url=$(echo "$clone_url" | sed 's|git@github.com:|https://github.com/|' | sed 's|\.git$||')
      fi
      [[ "$clone_url" == *.git ]] || clone_url="${clone_url}.git"
      clone_url_q=$(_adopt_shell_quote "$clone_url")
      # shellcheck disable=SC2029
      ssh $ssh_opts "$user@$host" "
        set -e
        git clone \
          -c 'url.https://oauth2:$gh_pat@github.com/.insteadOf=https://github.com/' \
          -c 'url.https://oauth2:$gh_pat@github.com/.insteadOf=git@github.com:' \
          --branch $branch_q \
          $clone_url_q $deploy_dir_q
      " || fail "Failed to clone repository. Check GH_PAT and repository access."
    else
      setup_strut_repo "$user" "$host" "$port" "$ssh_key" "$repo_url" "$deploy_dir"
      # shellcheck disable=SC2029
      ssh $ssh_opts "$user@$host" "cd $deploy_dir_q && git checkout $branch_q" 2>/dev/null || true
    fi
    ok "Fresh strut checkout cloned to $deploy_dir"
  fi

  # shellcheck disable=SC2029
  ssh $ssh_opts "$user@$host" "chmod +x ${deploy_dir_q}/strut" 2>/dev/null || true
}

# ── Phase 5: pull, merge, and encrypt env ───────────────────────────────────

# _adopt_pull_env <ssh_opts> <user> <host> <remote_env_path> <stack_dir> <env_name>
#                 <vps_host> <vps_user> <vps_port> <vps_ssh_key> <vps_deploy_dir> <force>
#
# Pulls the live .env from the remote, merges in the resolved connection
# fields (so the written file also works as strut's own connection env for
# this stack going forward), writes it to the stack-level path (refusing to
# clobber an existing one without <force>, matching _secrets_pull's own
# guard), then encrypts it via the existing _secrets_lock (age/gpg, reused
# unchanged — reads CMD_STACK/CMD_STACK_DIR/CMD_ENV_NAME globals, already
# correctly populated by the dispatcher for this invocation).
_adopt_pull_env() {
  local ssh_opts="$1" user="$2" host="$3" remote_env_path="$4" stack_dir="$5" env_name="$6"
  local vps_host="$7" vps_user="$8" vps_port="$9" vps_ssh_key="${10}" vps_deploy_dir="${11}" force="${12}"

  local local_env="$stack_dir/.${env_name}.env"
  if [ -f "$local_env" ] && [ "$force" != "true" ]; then
    fail "Local env file already exists: $local_env. Use --force to overwrite."
  fi

  local remote_env_path_q
  remote_env_path_q=$(_adopt_shell_quote "$remote_env_path")
  # shellcheck disable=SC2029
  if ! ssh $ssh_opts "$user@$host" "test -f $remote_env_path_q" 2>/dev/null; then
    warn "No live env file found at $remote_env_path — writing connection settings only. Add application secrets manually before deploying."
  fi

  local remote_content
  remote_content=$(_adopt_fetch_remote_file "$ssh_opts" "$user" "$host" "$remote_env_path")

  mkdir -p "$stack_dir"
  local tmp_env
  tmp_env=$(mktemp "${local_env}.XXXXXX") || fail "Could not create temp file"
  {
    echo "VPS_HOST=$vps_host"
    echo "VPS_USER=$vps_user"
    [ "$vps_port" != "22" ] && echo "VPS_PORT=$vps_port"
    [ -n "$vps_ssh_key" ] && echo "VPS_SSH_KEY=$vps_ssh_key"
    echo "VPS_DEPLOY_DIR=$vps_deploy_dir"
    echo ""
    echo "# ── Pulled from live host ($host:$remote_env_path) ──"
    [ -n "$remote_content" ] && echo "$remote_content"
  } > "$tmp_env"
  chmod 600 "$tmp_env"
  mv "$tmp_env" "$local_env"
  ok "Wrote $local_env"

  if declare -F _secrets_lock >/dev/null 2>&1; then
    _secrets_lock || warn "Could not encrypt the pulled env automatically — run manually: strut $CMD_STACK secrets lock --env $env_name"
  fi
}

# ── Phase 6: mark adopted ───────────────────────────────────────────────────

# _adopt_mark <stack_dir> <host> <project_name> <live_working_dir>
#
# Writes stacks/<stack>/.strut-adopted — a flat key=value marker, same
# rationale as .bluegreen's state file (lib/deploy_blue_green.sh): avoid a
# jq dependency on the fast path. Records that this stack was brought under
# strut via adopt, and from where.
_adopt_mark() {
  local stack_dir="$1" host="$2" project_name="$3" live_working_dir="$4"
  local marker="$stack_dir/.strut-adopted"
  mkdir -p "$stack_dir"
  {
    echo "adopted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "source_host=$host"
    echo "source_project_name=$project_name"
    echo "source_working_dir=$live_working_dir"
  } > "$marker"
  ok "Marked stack as adopted: $marker"
}

# ── Main command ─────────────────────────────────────────────────────────────

# cmd_adopt [options] (reads CMD_* when available)
cmd_adopt() {
  local host="" user="" ssh_key="" port="" repo_url="" branch="main" deploy_dir_flag=""
  local remote_dir="" remote_env_file="" remote_compose_file=""
  local dry_run="${DRY_RUN:-false}"
  local force=false

  local stack="${CMD_STACK:-}"
  local stack_dir="${CMD_STACK_DIR:-}"
  local env_name="${CMD_ENV_NAME:-prod}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host) host="$2"; shift 2 ;;
      --user) user="$2"; shift 2 ;;
      --key) ssh_key="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --repo) repo_url="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --deploy-dir) deploy_dir_flag="$2"; shift 2 ;;
      --remote-dir) remote_dir="$2"; shift 2 ;;
      --remote-env-file) remote_env_file="$2"; shift 2 ;;
      --remote-compose-file) remote_compose_file="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --force) force=true; shift ;;
      --help|-h) _usage_adopt; return 0 ;;
      *) shift ;;
    esac
  done

  [ -n "$stack" ] || fail "adopt must be run as: strut <stack> adopt ..."
  [ -n "$stack_dir" ] || stack_dir="$CLI_ROOT/stacks/$stack"

  host="${host:-${VPS_HOST:-}}"
  user="${user:-${VPS_USER:-ubuntu}}"
  ssh_key="${ssh_key:-${VPS_SSH_KEY:-}}"
  port="${port:-${VPS_PORT:-22}}"
  branch="${branch:-${DEFAULT_BRANCH:-main}}"

  [ -n "$host" ] || fail "--host is required (or set VPS_HOST)."

  local compose_file="$stack_dir/docker-compose.yml"
  [ -f "$compose_file" ] || fail "No committed compose file found at $compose_file — adopt expects the stack to already be strut-configured. Scaffold it first: strut scaffold $stack"

  if [ -z "$repo_url" ]; then
    repo_url=$(git remote get-url origin 2>/dev/null || echo "")
    [ -n "$repo_url" ] || fail "Could not detect git remote URL. Use --repo <url> to specify."
  fi

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$port" -k "$ssh_key" --batch)

  # Resolve the deploy dir using THIS invocation's user, not whatever might
  # already be exported globally — a stack being adopted may have no env
  # file yet, or one pointing at a different host/user entirely.
  local deploy_dir="$deploy_dir_flag"
  if [ -z "$deploy_dir" ]; then
    local _prev_vps_user="${VPS_USER:-}" _prev_vps_deploy_dir="${VPS_DEPLOY_DIR:-}"
    export VPS_USER="$user"
    unset VPS_DEPLOY_DIR 2>/dev/null || true
    deploy_dir=$(resolve_deploy_dir)
    [ -n "$_prev_vps_user" ] && export VPS_USER="$_prev_vps_user" || unset VPS_USER
    [ -n "$_prev_vps_deploy_dir" ] && export VPS_DEPLOY_DIR="$_prev_vps_deploy_dir"
  fi

  print_banner "Adopt Stack"
  log "Stack: $stack | Env: $env_name"
  log "Target: $user@$host:$port"
  log "Fresh checkout will be cloned to: $deploy_dir"
  echo ""

  # ── Step 1: SSH connectivity ────────────────────────────────────────────
  log "[1/6] Testing SSH connectivity..."
  if ! ssh $ssh_opts "$user@$host" "echo ok" >/dev/null 2>&1; then
    fail "Cannot connect to $user@$host (port $port). Check host, user, and SSH key."
  fi
  ok "SSH connection successful"

  # ── Step 1b: discover the live compose project ──────────────────────────
  log "[2/6] Discovering the live compose project..."
  local live_working_dir live_project_name
  if [ -n "$remote_dir" ]; then
    live_working_dir="$remote_dir"
    live_project_name=$(_adopt_project_name_at "$ssh_opts" "$user" "$host" "$remote_dir")
    if [ -n "$live_project_name" ]; then
      ok "Using explicit --remote-dir: $live_working_dir (project: $live_project_name)"
    else
      ok "Using explicit --remote-dir: $live_working_dir (no running containers detected there — proceeding anyway)"
    fi
  else
    if ! _adopt_discover "$ssh_opts" "$user" "$host" "$stack" "$env_name"; then
      fail "Could not uniquely identify the live compose project for '$stack' (checked names '$stack' and '${stack}-${env_name}'). Re-run with --remote-dir <path> to specify it explicitly."
    fi
    live_working_dir="$ADOPT_DISCOVERED_WORKING_DIR"
    live_project_name="$ADOPT_DISCOVERED_PROJECT_NAME"
    ok "Found running project '$live_project_name' at $live_working_dir"
  fi

  local remote_compose_path="${remote_compose_file:-$live_working_dir/docker-compose.yml}"
  local remote_env_path="${remote_env_file:-$live_working_dir/.env}"

  # ── Step 2: verify committed compose matches what's live ────────────────
  log "[3/6] Verifying committed compose matches the live compose file..."
  if ! _adopt_verify_compose "$ssh_opts" "$user" "$host" "$remote_compose_path" "$compose_file"; then
    if [ "$force" = "true" ]; then
      warn "Proceeding despite compose mismatch (--force)"
    else
      fail "Committed compose file doesn't match what's running. Re-run with --force to proceed anyway (review the diff above first)."
    fi
  fi

  # ── Step 3: detect data-at-risk (report only, never blocks) ─────────────
  log "[4/6] Checking for data/volumes living inside the checkout..."
  _adopt_detect_data "$ssh_opts" "$user" "$host" "$live_working_dir" "$compose_file" "$stack" "$deploy_dir"

  if [ "$dry_run" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Remaining steps (not executed):${NC}"
    run_cmd "Clone fresh strut checkout" ssh "$user@$host" "git clone --branch $branch $repo_url $deploy_dir"
    run_cmd "Pull live env file" scp "$user@$host:$remote_env_path" "$stack_dir/.${env_name}.env"
    run_cmd "Encrypt pulled env" echo "strut $stack secrets lock --env $env_name"
    run_cmd "Write adoption marker" echo "$stack_dir/.strut-adopted"
    run_cmd "Confirm new checkout is clean" echo "fleet_sync --dry-run against $deploy_dir"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  # ── Step 4: bootstrap a fresh, separate strut checkout ───────────────────
  log "[5/6] Cloning a fresh strut checkout (never touches the live directory)..."
  if [ "${deploy_dir%/}" = "${live_working_dir%/}" ]; then
    fail "Resolved deploy dir ($deploy_dir) is the same as the live project's directory — refusing to proceed, since adopt must never run git operations against a directory holding live data. Pass --deploy-dir <different path>."
  fi
  _adopt_bootstrap_checkout "$ssh_opts" "$user" "$host" "$port" "$ssh_key" "$repo_url" "$branch" "$deploy_dir"

  # ── Step 5: pull + merge + encrypt the live env ──────────────────────────
  log "[6/6] Pulling live config and marking the stack as adopted..."
  _adopt_pull_env "$ssh_opts" "$user" "$host" "$remote_env_path" "$stack_dir" "$env_name" \
    "$host" "$user" "$port" "$ssh_key" "$deploy_dir" "$force"

  # ── Step 6: mark adopted + confirm safe ──────────────────────────────────
  _adopt_mark "$stack_dir" "$host" "$live_project_name" "$live_working_dir"

  echo ""
  log "Confirming the fresh checkout is clean..."
  fleet_sync "$user" "$host" "$port" "$ssh_key" "$deploy_dir" "$branch" "${GH_PAT:-}" --dry-run || true

  echo ""
  ok "Adoption complete!"
  echo ""
  echo "Next steps:"
  echo "  1. Review the pulled env: strut $stack secrets unlock --env $env_name"
  echo "  2. If it differs from strut's default naming, set COMPOSE_PROJECT_NAME=$live_project_name"
  echo "     in stacks/$stack/.${env_name}.env (before re-locking) so a deploy targets"
  echo "     the already-running containers instead of starting new ones."
  echo "  3. Relocate any data reported above, per the printed guidance, when ready."
  echo "  4. strut $stack deploy --env $env_name --dry-run"
}
