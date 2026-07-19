#!/usr/bin/env bash
# ==================================================
# lib/hook_helpers.sh — Hook helper stdlib
# ==================================================
# Idempotent, sudo-aware helpers for hook scripts (stacks/<stack>/hooks/*.sh)
# that install host companions (systemd units/timers, udev rules, /etc/default
# files, binaries, packages) without hand-rolling the install/reload/enable
# dance every time.
#
# Hooks run as a fresh `bash "$hook_file"` process (lib/hooks.sh) and do NOT
# inherit strut's shell functions, so this file is self-contained — it does
# not require utils.sh to be sourced first. Opt-in, not auto-sourced:
#
#   . "$STRUT_LIB/hook_helpers.sh"
#   strut::install_unit ./foo.service --now
#
# All state-touching helpers honor DRY_RUN=true (print intended action, touch
# nothing) and record what they install to a per-stack manifest at
# ${STRUT_STATE_DIR:-/var/lib/strut}/<stack>/installed.list, which a future
# generic uninstall can walk.
#
# Install roots are overridable via env vars so tests (and non-standard
# hosts) can redirect writes without root:
#   STRUT_SYSTEMD_DIR   (default /etc/systemd/system)
#   STRUT_UDEV_DIR       (default /etc/udev/rules.d)
#   STRUT_DEFAULT_DIR    (default /etc/default)
#   STRUT_STATE_DIR       (default /var/lib/strut)

set -euo pipefail

# ── Self-contained logging fallbacks ─────────────────────────────────────────
# Keep whatever the caller already defined (e.g. utils.sh, or a test's
# overrides) — only fill in gaps for standalone hook execution.
declare -F log   >/dev/null 2>&1 || log()   { echo "[strut] $*"; }
declare -F ok    >/dev/null 2>&1 || ok()    { echo "✓ $*"; }
declare -F warn  >/dev/null 2>&1 || warn()  { echo "⚠ $*" >&2; }
declare -F error >/dev/null 2>&1 || error() { echo "✗ $*" >&2; }
declare -F fail  >/dev/null 2>&1 || fail()  { echo "✗ $*" >&2; exit 1; }

# ── Internal helpers ──────────────────────────────────────────────────────────

_strut_dry_run() { [ "${DRY_RUN:-false}" = "true" ]; }

# _strut_sudo — echoes "sudo" when not running as root, empty string otherwise.
_strut_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "sudo"
  fi
}

# _strut_exec <cmd...> — runs (or DRY-RUN prints) a privileged command.
_strut_exec() {
  if _strut_dry_run; then
    echo -e "  ${YELLOW:-}[DRY-RUN]${NC:-} Would run: $*"
    return 0
  fi
  if [ -n "$(_strut_sudo)" ]; then
    sudo "$@"
  else
    "$@"
  fi
}

# _strut_changed <src> <dest> — true (0) if dest is missing or differs from src.
_strut_changed() {
  local src="$1" dest="$2"
  [ -f "$dest" ] || return 0
  cmp -s "$src" "$dest" && return 1
  return 0
}

_strut_stack_name() {
  echo "${CMD_STACK:-${STRUT_STACK:-default}}"
}

_strut_manifest_path() {
  local state_dir="${STRUT_STATE_DIR:-/var/lib/strut}"
  echo "$state_dir/$(_strut_stack_name)/installed.list"
}

# _strut_record <path> — appends <path> to the per-stack manifest, deduped.
_strut_record() {
  local path="$1"
  _strut_dry_run && return 0

  local manifest manifest_dir
  manifest="$(_strut_manifest_path)"
  manifest_dir="$(dirname "$manifest")"

  if [ -n "$(_strut_sudo)" ]; then
    sudo mkdir -p "$manifest_dir"
    sudo touch "$manifest"
    grep -qxF "$path" "$manifest" 2>/dev/null || echo "$path" | sudo tee -a "$manifest" >/dev/null
  else
    mkdir -p "$manifest_dir"
    touch "$manifest"
    grep -qxF "$path" "$manifest" 2>/dev/null || echo "$path" >> "$manifest"
  fi
}

# ── Public helpers ────────────────────────────────────────────────────────────

# strut::require_pkg <pkg...> — install-if-missing via apt/dnf/yum.
strut::require_pkg() {
  local pkg
  for pkg in "$@"; do
    if dpkg -s "$pkg" >/dev/null 2>&1 || rpm -q "$pkg" >/dev/null 2>&1; then
      continue
    fi

    if _strut_dry_run; then
      echo -e "  ${YELLOW:-}[DRY-RUN]${NC:-} Would install package: $pkg"
      continue
    fi

    if command -v apt-get >/dev/null 2>&1; then
      _strut_exec apt-get install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
      _strut_exec dnf install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then
      _strut_exec yum install -y "$pkg"
    else
      warn "No supported package manager found (apt/dnf/yum) — cannot install: $pkg"
      return 1
    fi
    ok "Installed package: $pkg"
  done
}

# strut::install_unit <file.service> [--now] — install + daemon-reload + enable,
# only on change. Quiet no-op when unit content is unchanged.
strut::install_unit() {
  local src="$1"
  local now_flag=""
  [ "${2:-}" = "--now" ] && now_flag="1"

  local name dest
  name="$(basename "$src")"
  dest="${STRUT_SYSTEMD_DIR:-/etc/systemd/system}/$name"

  if _strut_dry_run; then
    if _strut_changed "$src" "$dest"; then
      echo -e "  ${YELLOW:-}[DRY-RUN]${NC:-} Would install unit $name, reload, and enable${now_flag:+ --now}"
    fi
    return 0
  fi

  _strut_changed "$src" "$dest" || return 0

  _strut_exec install -m 0644 "$src" "$dest"
  _strut_record "$dest"
  _strut_exec systemctl daemon-reload

  if [ -n "$now_flag" ]; then
    _strut_exec systemctl enable --now "$name"
  else
    _strut_exec systemctl enable "$name"
  fi
  log "Installed unit: $name"
}

# strut::install_timer <file.timer> <file.service> — installs both, reloads,
# enables --now the timer. Only on change; quiet no-op otherwise.
strut::install_timer() {
  local timer_src="$1"
  local service_src="$2"

  local timer_name service_name systemd_dir timer_dest service_dest
  timer_name="$(basename "$timer_src")"
  service_name="$(basename "$service_src")"
  systemd_dir="${STRUT_SYSTEMD_DIR:-/etc/systemd/system}"
  timer_dest="$systemd_dir/$timer_name"
  service_dest="$systemd_dir/$service_name"

  if _strut_dry_run; then
    if _strut_changed "$timer_src" "$timer_dest" || _strut_changed "$service_src" "$service_dest"; then
      echo -e "  ${YELLOW:-}[DRY-RUN]${NC:-} Would install timer $timer_name + $service_name, reload, and enable --now"
    fi
    return 0
  fi

  local changed=""
  if _strut_changed "$service_src" "$service_dest"; then
    _strut_exec install -m 0644 "$service_src" "$service_dest"
    _strut_record "$service_dest"
    changed=1
  fi
  if _strut_changed "$timer_src" "$timer_dest"; then
    _strut_exec install -m 0644 "$timer_src" "$timer_dest"
    _strut_record "$timer_dest"
    changed=1
  fi

  [ -z "$changed" ] && return 0

  _strut_exec systemctl daemon-reload
  _strut_exec systemctl enable --now "$timer_name"
  log "Installed timer: $timer_name"
}

# strut::install_udev <file.rules> — install + udevadm reload/trigger, only on change.
strut::install_udev() {
  local src="$1"
  local name dest
  name="$(basename "$src")"
  dest="${STRUT_UDEV_DIR:-/etc/udev/rules.d}/$name"

  if _strut_dry_run; then
    if _strut_changed "$src" "$dest"; then
      echo -e "  ${YELLOW:-}[DRY-RUN]${NC:-} Would install udev rule $name and reload"
    fi
    return 0
  fi

  _strut_changed "$src" "$dest" || return 0

  _strut_exec install -m 0644 "$src" "$dest"
  _strut_record "$dest"
  _strut_exec udevadm control --reload
  _strut_exec udevadm trigger
  log "Installed udev rule: $name"
}

# strut::install_default <name> KEY=val [KEY2=val...] — render /etc/default/<name>,
# only on change.
strut::install_default() {
  local name="$1"
  shift

  local dest="${STRUT_DEFAULT_DIR:-/etc/default}/$name"
  local tmp
  tmp="$(mktemp)"
  local kv
  for kv in "$@"; do
    echo "$kv"
  done > "$tmp"

  if _strut_dry_run; then
    if _strut_changed "$tmp" "$dest"; then
      echo -e "  ${YELLOW:-}[DRY-RUN]${NC:-} Would render /etc/default/$name"
    fi
    rm -f "$tmp"
    return 0
  fi

  if ! _strut_changed "$tmp" "$dest"; then
    rm -f "$tmp"
    return 0
  fi

  _strut_exec install -m 0644 "$tmp" "$dest"
  _strut_record "$dest"
  rm -f "$tmp"
  log "Rendered /etc/default/$name"
}

# strut::install_bin <src> <dest> — install -m 0755, only on change.
strut::install_bin() {
  local src="$1"
  local dest="$2"

  if _strut_dry_run; then
    if _strut_changed "$src" "$dest"; then
      echo -e "  ${YELLOW:-}[DRY-RUN]${NC:-} Would install $dest"
    fi
    return 0
  fi

  _strut_changed "$src" "$dest" || return 0

  _strut_exec mkdir -p "$(dirname "$dest")"
  _strut_exec install -m 0755 "$src" "$dest"
  _strut_record "$dest"
  log "Installed: $dest"
}
