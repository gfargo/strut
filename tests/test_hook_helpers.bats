#!/usr/bin/env bats
# ==================================================
# tests/test_hook_helpers.bats — lib/hook_helpers.sh stdlib
# ==================================================
# Run:  bats tests/test_hook_helpers.bats
#
# All install roots are redirected into $TEST_TMP so nothing touches the
# real filesystem, and _strut_sudo is forced to report "running as root"
# so the library never shells out to a real `sudo` binary.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers (mirrors tests/test_hooks.bats)
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  source "$CLI_ROOT/lib/hook_helpers.sh"

  # Redirect every install root under TEST_TMP.
  export STRUT_SYSTEMD_DIR="$TEST_TMP/systemd"
  export STRUT_UDEV_DIR="$TEST_TMP/udev"
  export STRUT_DEFAULT_DIR="$TEST_TMP/default"
  export STRUT_STATE_DIR="$TEST_TMP/state"
  mkdir -p "$STRUT_SYSTEMD_DIR" "$STRUT_UDEV_DIR" "$STRUT_DEFAULT_DIR" "$STRUT_STATE_DIR"

  export CMD_STACK="teststack"

  # Simulate root — no real `sudo` binary needed.
  # shellcheck disable=SC2317
  _strut_sudo() { :; }
  export -f _strut_sudo

  # Stub systemctl/udevadm/apt-get so we can assert calls without a real
  # systemd/udev/package manager.
  SYSTEMCTL_LOG="$TEST_TMP/systemctl_calls.log"
  : > "$SYSTEMCTL_LOG"
  export SYSTEMCTL_LOG
  # shellcheck disable=SC2317
  systemctl() { echo "$*" >> "$SYSTEMCTL_LOG"; }
  export -f systemctl

  UDEVADM_LOG="$TEST_TMP/udevadm_calls.log"
  : > "$UDEVADM_LOG"
  export UDEVADM_LOG
  # shellcheck disable=SC2317
  udevadm() { echo "$*" >> "$UDEVADM_LOG"; }
  export -f udevadm

  APT_LOG="$TEST_TMP/apt_calls.log"
  : > "$APT_LOG"
  export APT_LOG
  # shellcheck disable=SC2317
  apt-get() { echo "$*" >> "$APT_LOG"; }
  export -f apt-get
}

teardown() { common_teardown; }

manifest_file() {
  echo "$STRUT_STATE_DIR/$CMD_STACK/installed.list"
}

# ── install_unit ───────────────────────────────────────────────────────────

@test "install_unit: installs, reloads, and enables on first run" {
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF

  run strut::install_unit "$TEST_TMP/foo.service"
  [ "$status" -eq 0 ]
  [ -f "$STRUT_SYSTEMD_DIR/foo.service" ]
  grep -q "daemon-reload" "$SYSTEMCTL_LOG"
  grep -q "enable foo.service" "$SYSTEMCTL_LOG"
  ! grep -q -- "--now" "$SYSTEMCTL_LOG"
}

@test "install_unit: --now enables with --now" {
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF

  run strut::install_unit "$TEST_TMP/foo.service" --now
  [ "$status" -eq 0 ]
  grep -q -- "enable --now foo.service" "$SYSTEMCTL_LOG"
}

@test "install_unit: idempotent no-op on rerun (unchanged content)" {
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF
  strut::install_unit "$TEST_TMP/foo.service"
  : > "$SYSTEMCTL_LOG"

  run strut::install_unit "$TEST_TMP/foo.service"
  [ "$status" -eq 0 ]
  [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "install_unit: change-detection triggers reload on content change" {
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF
  strut::install_unit "$TEST_TMP/foo.service"
  : > "$SYSTEMCTL_LOG"

  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo v2
EOF
  run strut::install_unit "$TEST_TMP/foo.service"
  [ "$status" -eq 0 ]
  grep -q "daemon-reload" "$SYSTEMCTL_LOG"
  diff "$TEST_TMP/foo.service" "$STRUT_SYSTEMD_DIR/foo.service"
}

@test "install_unit: DRY_RUN touches nothing" {
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF
  export DRY_RUN=true
  run strut::install_unit "$TEST_TMP/foo.service" --now
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [ ! -f "$STRUT_SYSTEMD_DIR/foo.service" ]
  [ ! -s "$SYSTEMCTL_LOG" ]
  [ ! -f "$(manifest_file)" ]
}

@test "install_unit: records installed path to manifest" {
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF
  strut::install_unit "$TEST_TMP/foo.service"
  grep -qxF "$STRUT_SYSTEMD_DIR/foo.service" "$(manifest_file)"
}

# ── install_timer ──────────────────────────────────────────────────────────

@test "install_timer: installs both files, reloads, enables --now the timer" {
  cat > "$TEST_TMP/foo.timer" <<'EOF'
[Timer]
OnCalendar=daily
EOF
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF

  run strut::install_timer "$TEST_TMP/foo.timer" "$TEST_TMP/foo.service"
  [ "$status" -eq 0 ]
  [ -f "$STRUT_SYSTEMD_DIR/foo.timer" ]
  [ -f "$STRUT_SYSTEMD_DIR/foo.service" ]
  grep -q "daemon-reload" "$SYSTEMCTL_LOG"
  grep -q -- "enable --now foo.timer" "$SYSTEMCTL_LOG"
}

@test "install_timer: idempotent no-op on rerun" {
  cat > "$TEST_TMP/foo.timer" <<'EOF'
[Timer]
OnCalendar=daily
EOF
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF
  strut::install_timer "$TEST_TMP/foo.timer" "$TEST_TMP/foo.service"
  : > "$SYSTEMCTL_LOG"

  run strut::install_timer "$TEST_TMP/foo.timer" "$TEST_TMP/foo.service"
  [ "$status" -eq 0 ]
  [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "install_timer: DRY_RUN touches nothing" {
  cat > "$TEST_TMP/foo.timer" <<'EOF'
[Timer]
OnCalendar=daily
EOF
  cat > "$TEST_TMP/foo.service" <<'EOF'
[Unit]
Description=foo
EOF
  export DRY_RUN=true
  run strut::install_timer "$TEST_TMP/foo.timer" "$TEST_TMP/foo.service"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [ ! -f "$STRUT_SYSTEMD_DIR/foo.timer" ]
  [ ! -f "$STRUT_SYSTEMD_DIR/foo.service" ]
  [ ! -s "$SYSTEMCTL_LOG" ]
  [ ! -f "$(manifest_file)" ]
}

# ── install_udev ───────────────────────────────────────────────────────────

@test "install_udev: installs and reloads/triggers on first run" {
  cat > "$TEST_TMP/99-foo.rules" <<'EOF'
SUBSYSTEM=="tty", SYMLINK+="foo"
EOF

  run strut::install_udev "$TEST_TMP/99-foo.rules"
  [ "$status" -eq 0 ]
  [ -f "$STRUT_UDEV_DIR/99-foo.rules" ]
  grep -q "control --reload" "$UDEVADM_LOG"
  grep -q "trigger" "$UDEVADM_LOG"
}

@test "install_udev: idempotent no-op on rerun" {
  cat > "$TEST_TMP/99-foo.rules" <<'EOF'
SUBSYSTEM=="tty", SYMLINK+="foo"
EOF
  strut::install_udev "$TEST_TMP/99-foo.rules"
  : > "$UDEVADM_LOG"

  run strut::install_udev "$TEST_TMP/99-foo.rules"
  [ "$status" -eq 0 ]
  [ ! -s "$UDEVADM_LOG" ]
}

@test "install_udev: DRY_RUN touches nothing" {
  cat > "$TEST_TMP/99-foo.rules" <<'EOF'
SUBSYSTEM=="tty", SYMLINK+="foo"
EOF
  export DRY_RUN=true
  run strut::install_udev "$TEST_TMP/99-foo.rules"
  [ "$status" -eq 0 ]
  [ ! -f "$STRUT_UDEV_DIR/99-foo.rules" ]
  [ ! -s "$UDEVADM_LOG" ]
}

# ── install_default ────────────────────────────────────────────────────────

@test "install_default: renders KEY=val pairs" {
  run strut::install_default foo FOO=bar BAZ=qux
  [ "$status" -eq 0 ]
  [ -f "$STRUT_DEFAULT_DIR/foo" ]
  grep -qxF "FOO=bar" "$STRUT_DEFAULT_DIR/foo"
  grep -qxF "BAZ=qux" "$STRUT_DEFAULT_DIR/foo"
}

@test "install_default: idempotent no-op when unchanged" {
  strut::install_default foo FOO=bar
  local before
  before="$(stat -c %Y "$STRUT_DEFAULT_DIR/foo" 2>/dev/null || stat -f %m "$STRUT_DEFAULT_DIR/foo")"
  sleep 1
  run strut::install_default foo FOO=bar
  [ "$status" -eq 0 ]
  local after
  after="$(stat -c %Y "$STRUT_DEFAULT_DIR/foo" 2>/dev/null || stat -f %m "$STRUT_DEFAULT_DIR/foo")"
  [ "$before" -eq "$after" ]
}

@test "install_default: DRY_RUN touches nothing" {
  export DRY_RUN=true
  run strut::install_default foo FOO=bar
  [ "$status" -eq 0 ]
  [ ! -f "$STRUT_DEFAULT_DIR/foo" ]
}

@test "install_default: cleans up its mktemp scratch file when install fails" {
  # STRUT_DEFAULT_DIR's parent is a regular file, so `install` fails with
  # ENOTDIR — install_default must not leak the mktemp file on that path.
  touch "$TEST_TMP/not_a_dir"
  export STRUT_DEFAULT_DIR="$TEST_TMP/not_a_dir/default"

  local scratch="$TEST_TMP/scratch"
  mkdir -p "$scratch"
  export TMPDIR="$scratch"

  run strut::install_default foo FOO=bar

  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$scratch")" ]
}

# ── install_bin ────────────────────────────────────────────────────────────

@test "install_bin: installs with executable mode" {
  cat > "$TEST_TMP/foo.sh" <<'EOF'
#!/usr/bin/env bash
echo hi
EOF
  run strut::install_bin "$TEST_TMP/foo.sh" "$TEST_TMP/dest/foo"
  [ "$status" -eq 0 ]
  [ -x "$TEST_TMP/dest/foo" ]
}

@test "install_bin: idempotent no-op on rerun" {
  cat > "$TEST_TMP/foo.sh" <<'EOF'
#!/usr/bin/env bash
echo hi
EOF
  strut::install_bin "$TEST_TMP/foo.sh" "$TEST_TMP/dest/foo"
  run strut::install_bin "$TEST_TMP/foo.sh" "$TEST_TMP/dest/foo"
  [ "$status" -eq 0 ]
  # Manifest should only have one entry despite two installs.
  [ "$(grep -c -F "$TEST_TMP/dest/foo" "$(manifest_file)")" -eq 1 ]
}

@test "install_bin: DRY_RUN touches nothing" {
  cat > "$TEST_TMP/foo.sh" <<'EOF'
#!/usr/bin/env bash
echo hi
EOF
  export DRY_RUN=true
  run strut::install_bin "$TEST_TMP/foo.sh" "$TEST_TMP/dest/foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [ ! -f "$TEST_TMP/dest/foo" ]
  [ ! -f "$(manifest_file)" ]
}

# ── require_pkg ────────────────────────────────────────────────────────────

@test "require_pkg: skips install when package already present" {
  # shellcheck disable=SC2317
  dpkg() { return 0; }
  export -f dpkg

  run strut::require_pkg wireguard-tools
  [ "$status" -eq 0 ]
  [ ! -s "$APT_LOG" ]
}

@test "require_pkg: installs via apt-get when missing" {
  # shellcheck disable=SC2317
  dpkg() { return 1; }
  export -f dpkg
  # shellcheck disable=SC2317
  rpm() { return 1; }
  export -f rpm

  run strut::require_pkg wireguard-tools
  [ "$status" -eq 0 ]
  grep -q "install -y wireguard-tools" "$APT_LOG"
}

@test "require_pkg: DRY_RUN touches nothing" {
  # shellcheck disable=SC2317
  dpkg() { return 1; }
  export -f dpkg
  # shellcheck disable=SC2317
  rpm() { return 1; }
  export -f rpm

  export DRY_RUN=true
  run strut::require_pkg wireguard-tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [ ! -s "$APT_LOG" ]
}

# ── manifest dedup ─────────────────────────────────────────────────────────

@test "_strut_record: dedups repeated paths" {
  _strut_record "/some/path"
  _strut_record "/some/path"
  _strut_record "/some/path"
  [ "$(wc -l < "$(manifest_file)")" -eq 1 ]
}

@test "_strut_record: falls back to STRUT_STACK when CMD_STACK unset" {
  unset CMD_STACK
  export STRUT_STACK="otherstack"
  _strut_record "/some/path"
  grep -qxF "/some/path" "$STRUT_STATE_DIR/otherstack/installed.list"
}

# ── sudo-prefix selection by euid ────────────────────────────────────────

@test "_strut_sudo: reports no sudo needed when overridden as root" {
  result="$(_strut_sudo)"
  [ -z "$result" ]
}

@test "_strut_exec: uses sudo prefix when not root" {
  # shellcheck disable=SC2317
  _strut_sudo() { echo sudo; }
  export -f _strut_sudo
  # shellcheck disable=SC2317
  sudo() { echo "SUDO: $*"; }
  export -f sudo

  run _strut_exec systemctl daemon-reload
  [ "$status" -eq 0 ]
  [[ "$output" == "SUDO: systemctl daemon-reload" ]]
}
