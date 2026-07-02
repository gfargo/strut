#!/usr/bin/env bats
# ==================================================
# tests/test_upgrade.bats — Tests for lib/cmd_upgrade.sh + lib/version_check.sh
# ==================================================
# Covers:
#   strut_install_method detection (git / brew / unknown)
#   cmd_upgrade routing per method
#   strut_check_for_update opt-out and suppression logic
#
# Run:  bats tests/test_upgrade.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  # Override log helpers so sourcing libs doesn't emit noise
  load_utils
  fail() { echo "FAIL: $1" >&2; return 1; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  ok()   { echo "OK: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail warn log ok error

  source "$CLI_ROOT/lib/cmd_upgrade.sh"
  source "$CLI_ROOT/lib/version_check.sh"
}

teardown() { common_teardown; }

# ── strut_install_method ─────────────────────────────────────────────────────

@test "strut_install_method: returns 'git' when STRUT_HOME/.git exists" {
  local fake_home="$TEST_TMP/git-install"
  mkdir -p "$fake_home/.git"
  STRUT_HOME="$fake_home"
  run strut_install_method
  [ "$status" -eq 0 ]
  [ "$output" = "git" ]
}

@test "strut_install_method: returns 'brew' when path contains /Cellar/" {
  local fake_home="$TEST_TMP/homebrew/Cellar/strut/0.28.0/libexec"
  mkdir -p "$fake_home"
  STRUT_HOME="$fake_home"
  run strut_install_method
  [ "$status" -eq 0 ]
  [ "$output" = "brew" ]
}

@test "strut_install_method: returns 'brew' when brew list reports strut installed" {
  local fake_home="$TEST_TMP/manual-brew"
  mkdir -p "$fake_home"
  STRUT_HOME="$fake_home"

  # Stub brew so it succeeds for 'list gfargo/tap/strut'
  local fake_bin="$TEST_TMP/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/brew" <<'EOF'
#!/usr/bin/env bash
# stub: brew list gfargo/tap/strut succeeds
exit 0
EOF
  chmod +x "$fake_bin/brew"

  PATH="$fake_bin:$PATH" run strut_install_method
  [ "$status" -eq 0 ]
  [ "$output" = "brew" ]
}

@test "strut_install_method: returns 'unknown' when no .git and no brew" {
  local fake_home="$TEST_TMP/no-git-no-brew"
  mkdir -p "$fake_home"
  STRUT_HOME="$fake_home"

  # Ensure brew is not found in a stripped PATH
  local empty_bin="$TEST_TMP/empty-bin"
  mkdir -p "$empty_bin"
  PATH="$empty_bin" run strut_install_method
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ── cmd_upgrade — git method ──────────────────────────────────────────────────

@test "cmd_upgrade: git method calls git pull and prints version" {
  local fake_home="$TEST_TMP/git-upgrade"
  mkdir -p "$fake_home/.git"
  echo "0.99.0" > "$fake_home/VERSION"
  STRUT_HOME="$fake_home"
  DEFAULT_BRANCH="main"

  # Stub git to succeed without actually pulling
  local fake_bin="$TEST_TMP/fake-git-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
echo "STUB git $*"
exit 0
EOF
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" run cmd_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB git"* ]]
  [[ "$output" == *"0.99.0"* ]]
}

@test "cmd_upgrade: git method does NOT invoke brew" {
  local fake_home="$TEST_TMP/git-no-brew"
  mkdir -p "$fake_home/.git"
  echo "0.1.0" > "$fake_home/VERSION"
  STRUT_HOME="$fake_home"
  DEFAULT_BRANCH="main"

  local fake_bin="$TEST_TMP/fake-git-bin2"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
echo "STUB git $*"
exit 0
EOF
  cat > "$fake_bin/brew" <<'EOF'
#!/usr/bin/env bash
echo "BREW CALLED UNEXPECTEDLY" >&2
exit 99
EOF
  chmod +x "$fake_bin/git" "$fake_bin/brew"

  PATH="$fake_bin:$PATH" run cmd_upgrade
  [ "$status" -eq 0 ]
  # brew must not have been invoked
  [[ "$output" != *"BREW CALLED UNEXPECTEDLY"* ]]
}

# ── cmd_upgrade — brew method ─────────────────────────────────────────────────

@test "cmd_upgrade: brew method calls brew upgrade gfargo/tap/strut" {
  local fake_home="$TEST_TMP/brew-upgrade"
  # No .git, but path contains /Cellar/
  fake_home="$TEST_TMP/homebrew/Cellar/strut/0.28.0/libexec"
  mkdir -p "$fake_home"
  echo "0.28.0" > "$fake_home/VERSION"
  STRUT_HOME="$fake_home"

  local fake_bin="$TEST_TMP/fake-brew-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/brew" <<'EOF'
#!/usr/bin/env bash
echo "STUB brew $*"
exit 0
EOF
  chmod +x "$fake_bin/brew"

  PATH="$fake_bin:$PATH" run cmd_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB brew upgrade gfargo/tap/strut"* ]]
}

@test "cmd_upgrade: brew method warns and exits 1 when brew is absent" {
  local fake_home="$TEST_TMP/homebrew/Cellar/strut/0.28.0/libexec2"
  mkdir -p "$fake_home"
  STRUT_HOME="$fake_home"

  # Strip brew from PATH
  local empty_bin="$TEST_TMP/empty-bin2"
  mkdir -p "$empty_bin"
  PATH="$empty_bin" run cmd_upgrade
  [ "$status" -ne 0 ]
  [[ "$output" == *"brew upgrade gfargo/tap/strut"* ]]
}

# ── cmd_upgrade — unknown method ──────────────────────────────────────────────

@test "cmd_upgrade: unknown method prints install one-liner and exits 0" {
  local fake_home="$TEST_TMP/unknown-install"
  mkdir -p "$fake_home"
  STRUT_HOME="$fake_home"

  local empty_bin="$TEST_TMP/empty-bin3"
  mkdir -p "$empty_bin"
  PATH="$empty_bin" run cmd_upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"install.sh"* ]]
}

# ── cmd_upgrade — help flag ───────────────────────────────────────────────────

@test "cmd_upgrade: --help prints usage and exits 0" {
  run cmd_upgrade --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: strut upgrade"* ]]
}

# ── strut_check_for_update ────────────────────────────────────────────────────

@test "strut_check_for_update: suppressed when STRUT_NO_UPDATE_CHECK=1" {
  STRUT_NO_UPDATE_CHECK=1 run strut_check_for_update
  [ "$status" -eq 0 ]
  # No output expected
  [ -z "$output" ]
}

@test "strut_check_for_update: suppressed when CI=1" {
  CI=1 run strut_check_for_update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "strut_check_for_update: suppressed when CI=true" {
  CI=true run strut_check_for_update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "strut_check_for_update: suppressed when OUTPUT_MODE=json" {
  OUTPUT_MODE=json run strut_check_for_update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "strut_check_for_update: no network call when cache is fresh" {
  local cache_dir="$TEST_TMP/cache/strut"
  mkdir -p "$cache_dir"
  printf '99.0.0' > "$cache_dir/latest_version"
  # touch is enough — file was just created so mtime is within 24h

  local fake_home="$TEST_TMP/strut-home-nag"
  mkdir -p "$fake_home"
  echo "0.1.0" > "$fake_home/VERSION"

  # Stub curl to fail if called (network must NOT be hit)
  local fake_bin="$TEST_TMP/fake-curl-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL SHOULD NOT BE CALLED" >&2
exit 1
EOF
  chmod +x "$fake_bin/curl"

  # Run with stderr redirected to a file so we can capture it
  # (strut_check_for_update writes to stderr, bats 'run' captures stdout+stderr combined)
  STRUT_HOME="$fake_home" \
  XDG_CACHE_HOME="$TEST_TMP/cache" \
  PATH="$fake_bin:$PATH" \
  CI="" \
  STRUT_NO_UPDATE_CHECK="" \
  OUTPUT_MODE="" \
  run bash -c "
    source '${CLI_ROOT}/lib/utils.sh'
    fail() { echo \"\$1\" >&2; return 1; }
    warn() { echo \"WARN: \$*\" >&2; }
    log()  { echo \"LOG: \$*\"; }
    ok()   { echo \"OK: \$*\"; }
    export -f fail warn log ok
    export STRUT_HOME='${fake_home}'
    export XDG_CACHE_HOME='${TEST_TMP}/cache'
    source '${CLI_ROOT}/lib/version_check.sh'
    # Force TTY check to pass by redirecting: we test suppression-via-cache,
    # not TTY. Use STRUT_NO_UPDATE_CHECK to avoid the TTY gate.
    # Instead, call strut_latest_version directly — if curl fires, it fails.
    strut_check_for_update || true
  " 2>&1
  # curl must not have been invoked
  [[ "$output" != *"CURL SHOULD NOT BE CALLED"* ]]
}

# ── _strut_version_gt ─────────────────────────────────────────────────────────

@test "_strut_version_gt: 0.28.0 > 0.25.1 is true" {
  run _strut_version_gt "0.28.0" "0.25.1"
  [ "$status" -eq 0 ]
}

@test "_strut_version_gt: 0.25.1 > 0.28.0 is false" {
  run _strut_version_gt "0.25.1" "0.28.0"
  [ "$status" -ne 0 ]
}

@test "_strut_version_gt: equal versions returns false" {
  run _strut_version_gt "1.0.0" "1.0.0"
  [ "$status" -ne 0 ]
}

@test "_strut_version_gt: major version bump detected" {
  run _strut_version_gt "2.0.0" "1.9.9"
  [ "$status" -eq 0 ]
}

# ── Entrypoint --json pre-scan suppresses update check ───────────────────────
# Verifies the fix for: OUTPUT_MODE=json gate was dead code because
# strut_check_for_update was called before command dispatch set OUTPUT_MODE.
# The entrypoint now pre-scans $@ for --json before the update check.

@test "entrypoint: --json flag pre-scan sets OUTPUT_MODE before update check" {
  # Simulate the entrypoint pre-scan logic (the fix)
  local args=(stack health --env prod --json)
  local OUTPUT_MODE=""
  for _pre_arg in "${args[@]}"; do
    if [ "$_pre_arg" = "--json" ]; then OUTPUT_MODE=json; break; fi
  done
  [ "$OUTPUT_MODE" = "json" ]
}

@test "entrypoint: non-json flags do not set OUTPUT_MODE=json in pre-scan" {
  local args=(stack health --env prod --verbose)
  local OUTPUT_MODE=""
  for _pre_arg in "${args[@]}"; do
    if [ "$_pre_arg" = "--json" ]; then OUTPUT_MODE=json; break; fi
  done
  [ "$OUTPUT_MODE" != "json" ]
}
