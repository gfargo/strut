#!/usr/bin/env bash
# ==================================================
# lib/lock.sh — Deploy concurrency locks (local + remote)
# ==================================================
# Prevents two deploys from racing against the same stack/env. A human
# running `strut deploy` while CI is also deploying the same stack can
# leave rollback snapshots colliding and containers half-updated.
#
# Two tiers:
#   - Local lock — ~/.strut/locks/<stack>-<env>.lock.d/
#   - Remote lock — <deploy_dir>/.strut-locks/<stack>-<env>.lock.d/ on VPS
#
# Atomicity uses `mkdir`, which is atomic on POSIX. A hidden `info` file
# inside stores pid/host/started/command so `lock status` and stale
# detection can see who's holding the lock.
#
# Tests override STRUT_LOCK_ROOT to avoid touching a real home dir.

set -euo pipefail

# Default stale threshold: 10 minutes.
: "${STRUT_LOCK_STALE_SECONDS:=600}"

# ── Local lock paths ──────────────────────────────────────────────────────────

lock_local_root() {
  echo "${STRUT_LOCK_ROOT:-$HOME/.strut/locks}"
}

lock_local_dir() {
  local stack="$1" env="${2:-default}"
  echo "$(lock_local_root)/${stack}-${env}.lock.d"
}

# ── Info file read/write ──────────────────────────────────────────────────────

_lock_write_info() {
  local dir="$1" cmd="$2"
  {
    echo "pid=$$"
    echo "host=$(hostname 2>/dev/null || echo unknown)"
    echo "started=$(date -u +%FT%TZ)"
    echo "command=$cmd"
  } > "$dir/info"
}

# lock_read_info <info_file> <field>
# Extracts a single value from a key=value info file.
lock_read_info() {
  local file="$1" field="$2"
  [ -f "$file" ] || return 1
  awk -F= -v k="$field" '$1==k { sub(/^[^=]*=/, "", $0); print; exit }' "$file"
}

# ── Acquire / release (local) ─────────────────────────────────────────────────

# lock_acquire_local <stack> <env> <command>
#   0 — acquired
#   1 — already held (prints holder to stderr)
#   2 — filesystem error
lock_acquire_local() {
  local stack="$1" env="${2:-default}" cmd="${3:-deploy}"
  local root dir
  root=$(lock_local_root)
  dir=$(lock_local_dir "$stack" "$env")

  mkdir -p "$root" 2>/dev/null || return 2

  if mkdir "$dir" 2>/dev/null; then
    _lock_write_info "$dir" "$cmd"
    return 0
  fi

  # Already held — report who
  local info="$dir/info"
  if [ -f "$info" ]; then
    local pid host started held_cmd
    pid=$(lock_read_info "$info" pid)
    host=$(lock_read_info "$info" host)
    started=$(lock_read_info "$info" started)
    held_cmd=$(lock_read_info "$info" command)
    echo "Deploy lock held by pid $pid on $host (command=$held_cmd, since $started)" >&2
  else
    echo "Deploy lock held (holder info missing)" >&2
  fi
  return 1
}

# lock_release_local <stack> <env>
#   Always returns 0. Safe to call from EXIT traps.
lock_release_local() {
  local stack="$1" env="${2:-default}"
  local dir
  dir=$(lock_local_dir "$stack" "$env")
  [ -d "$dir" ] && rm -rf "$dir"
  return 0
}

# ── Stale detection ───────────────────────────────────────────────────────────

# lock_is_stale_local <stack> <env>
#   0 — stale (holder pid dead on same host, OR age > threshold)
#   1 — not stale (still live)
#   2 — no lock
lock_is_stale_local() {
  local stack="$1" env="${2:-default}"
  local dir info
  dir=$(lock_local_dir "$stack" "$env")
  info="$dir/info"
  [ -f "$info" ] || return 2

  local pid host started
  pid=$(lock_read_info "$info" pid)
  host=$(lock_read_info "$info" host)
  started=$(lock_read_info "$info" started)

  local current_host
  current_host=$(hostname 2>/dev/null || echo unknown)

  # Same host + pid dead → definitely stale
  if [ "$host" = "$current_host" ] && [ -n "$pid" ]; then
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi

  # Age-based fallback (works for cross-host locks too)
  if [ -n "$started" ]; then
    local started_epoch now age
    # BSD date (macOS) uses -j -f; GNU date uses -d. Try both.
    started_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null \
      || date -u -d "$started" +%s 2>/dev/null \
      || echo 0)
    now=$(date -u +%s)
    age=$(( now - started_epoch ))
    if [ "$age" -gt "$STRUT_LOCK_STALE_SECONDS" ]; then
      return 0
    fi
  fi

  return 1
}

# ── Status / force-unlock ─────────────────────────────────────────────────────

# lock_status_local <stack> <env>
# Prints human-readable status. Exit 0 if held, 1 if not.
lock_status_local() {
  local stack="$1" env="${2:-default}"
  local dir info
  dir=$(lock_local_dir "$stack" "$env")
  info="$dir/info"
  if [ ! -f "$info" ]; then
    echo "Lock: not held (${stack}/${env})"
    return 1
  fi
  local pid host started cmd
  pid=$(lock_read_info "$info" pid)
  host=$(lock_read_info "$info" host)
  started=$(lock_read_info "$info" started)
  cmd=$(lock_read_info "$info" command)

  echo "Lock: held (${stack}/${env})"
  echo "  pid:     $pid"
  echo "  host:    $host"
  echo "  command: $cmd"
  echo "  started: $started"

  if lock_is_stale_local "$stack" "$env"; then
    echo "  status:  STALE — safe to break with: strut $stack lock release --force"
  else
    echo "  status:  active"
  fi
  return 0
}

# lock_force_break_local <stack> <env>
# Removes the lock unconditionally. Used by --force-unlock / `lock release --force`.
lock_force_break_local() {
  local stack="$1" env="${2:-default}"
  local dir
  dir=$(lock_local_dir "$stack" "$env")
  [ -d "$dir" ] && rm -rf "$dir"
  return 0
}

# ── Remote lock (thin SSH wrappers) ───────────────────────────────────────────
#
# These call into a remote shell snippet that runs the same mkdir-atomic
# primitive. They expect VPS_HOST / VPS_USER / SSH_KEY / SSH_PORT /
# VPS_DEPLOY_DIR to be set in the environment.

_lock_remote_dir_expr() {
  # Produces a shell expression (suitable for remote eval) that resolves
  # to the lock directory. Uses $HOME on the remote side if VPS_DEPLOY_DIR
  # is not set — matches the same default deploy dir as the rest of strut.
  local stack="$1" env="${2:-default}"
  echo "\${STRUT_LOCK_ROOT:-\${VPS_DEPLOY_DIR:-\$HOME/strut}/.strut-locks}/${stack}-${env}.lock.d"
}

# lock_acquire_remote <stack> <env> <command>
#   0 — acquired
#   1 — held (prints holder)
#   2 — ssh/env error
lock_acquire_remote() {
  local stack="$1" env="${2:-default}" cmd="${3:-deploy}"
  local host="${VPS_HOST:-}" user="${VPS_USER:-ubuntu}"
  [ -z "$host" ] && return 2
  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "${SSH_PORT:-22}" -k "${SSH_KEY:-}" --batch)
  local dir_expr
  dir_expr=$(_lock_remote_dir_expr "$stack" "$env")

  # shellcheck disable=SC2086
  ssh $ssh_opts "$user@$host" bash -s -- "$stack" "$env" "$cmd" <<REMOTE
set -eu
stack="\$1"; env="\$2"; cmd="\$3"
dir="$dir_expr"
mkdir -p "\$(dirname "\$dir")" 2>/dev/null || exit 2
if mkdir "\$dir" 2>/dev/null; then
  {
    echo "pid=\$\$"
    echo "host=\$(hostname)"
    echo "started=\$(date -u +%FT%TZ)"
    echo "command=\$cmd"
  } > "\$dir/info"
  exit 0
else
  [ -f "\$dir/info" ] && cat "\$dir/info" >&2
  exit 1
fi
REMOTE
}

# lock_release_remote <stack> <env>
lock_release_remote() {
  local stack="$1" env="${2:-default}"
  local host="${VPS_HOST:-}" user="${VPS_USER:-ubuntu}"
  [ -z "$host" ] && return 0
  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "${SSH_PORT:-22}" -k "${SSH_KEY:-}" --batch)
  local dir_expr
  dir_expr=$(_lock_remote_dir_expr "$stack" "$env")
  # shellcheck disable=SC2086
  ssh $ssh_opts "$user@$host" "rm -rf $dir_expr 2>/dev/null || true" >/dev/null 2>&1 || true
  return 0
}

# lock_status_remote <stack> <env>
# Dumps the remote info file (if any). 0 if held, 1 if not.
lock_status_remote() {
  local stack="$1" env="${2:-default}"
  local host="${VPS_HOST:-}" user="${VPS_USER:-ubuntu}"
  [ -z "$host" ] && return 1
  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "${SSH_PORT:-22}" -k "${SSH_KEY:-}" --batch)
  local dir_expr
  dir_expr=$(_lock_remote_dir_expr "$stack" "$env")
  # shellcheck disable=SC2086
  ssh $ssh_opts "$user@$host" "[ -f $dir_expr/info ] && cat $dir_expr/info || exit 1"
}

lock_force_break_remote() {
  lock_release_remote "$@"
}

# ── Convenience: full-stack acquire/release ───────────────────────────────────
#
# lock_acquire <stack> <env> <command>
#   Acquires local and (if VPS_HOST set) remote. On partial failure releases
#   what was taken so callers can't leak.
lock_acquire() {
  local stack="$1" env="${2:-default}" cmd="${3:-deploy}"
  lock_acquire_local "$stack" "$env" "$cmd" || return 1
  if [ -n "${VPS_HOST:-}" ]; then
    if ! lock_acquire_remote "$stack" "$env" "$cmd"; then
      lock_release_local "$stack" "$env"
      return 1
    fi
  fi
  return 0
}

# lock_release <stack> <env>
lock_release() {
  local stack="$1" env="${2:-default}"
  lock_release_local "$stack" "$env"
  [ -n "${VPS_HOST:-}" ] && lock_release_remote "$stack" "$env"
  return 0
}
