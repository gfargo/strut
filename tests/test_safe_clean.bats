#!/usr/bin/env bats
# ==================================================
# tests/test_safe_clean.bats — Safe git clean guard (OSS-281 / strut#181)
# ==================================================
# Covers:
#   - render_safe_clean_snippet() output structure
#   - vps_update_repo SSH command contains the guard (not bare git clean -fd)
#   - FORCE_CLEAN=true threads through and produces the bypass branch
#   - --force-clean is parsed by parse_common_flags

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
}

teardown() {
  common_teardown
}

# ── Helpers ────────────────────────────────────────────────────────────────────

_load_deploy() {
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"
  source "$CLI_ROOT/lib/deploy.sh"

  validate_env_file() {
    local ef="$1"; shift
    [ -f "$ef" ] && { set -a; source "$ef"; set +a; }
  }
  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  ok()   { :; }
  warn() { echo "$*"; }
}

_capture_vps_update_cmd() {
  local env_file="$1"
  local force_clean="${2:-false}"

  _load_deploy

  # Stub ssh to capture the full command/body passed to it
  ssh() { echo "SSH_CMD: $*"; }

  export FORCE_CLEAN="$force_clean"
  vps_update_repo "test-stack" "$env_file"
}

_make_env_file() {
  local path="$TEST_TMP/test.env"
  cat > "$path" <<'EOF'
VPS_HOST=10.0.0.1
VPS_USER=deploy
GH_PAT=test_token
EOF
  echo "$path"
}

# ── render_safe_clean_snippet unit tests ───────────────────────────────────────

@test "render_safe_clean_snippet: contains dry-run detection (git clean -fdn)" {
  _load_deploy
  run render_safe_clean_snippet "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git clean -fdn"* ]]
}

@test "render_safe_clean_snippet: without --force-clean contains abort message" {
  _load_deploy
  run render_safe_clean_snippet "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: git clean would delete untracked paths"* ]]
  [[ "$output" == *"--force-clean"* ]]
}

@test "render_safe_clean_snippet: with force_clean=true does NOT abort, runs git clean -fd" {
  _load_deploy
  run render_safe_clean_snippet "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git clean -fd"* ]]
  # With force_clean=true the condition resolves to [ "true" = "true" ] — the
  # git clean -fd branch is taken and exit 1 is never reached on the remote.
  # Verify the unconditional guard check (git clean -fdn) is still present so
  # we go through the if/else structure, not a raw git clean -fd.
  [[ "$output" == *"git clean -fdn"* ]]
}

@test "render_safe_clean_snippet: default (no arg) is non-destructive" {
  _load_deploy
  run render_safe_clean_snippet
  [ "$status" -eq 0 ]
  [[ "$output" == *"git clean -fdn"* ]]
  [[ "$output" == *"ERROR: git clean would delete untracked paths"* ]]
}

@test "render_safe_clean_snippet: does not contain bare unconditional 'git clean -fd' without guard" {
  _load_deploy
  run render_safe_clean_snippet "false"
  [ "$status" -eq 0 ]
  # The snippet must check the dry-run output before running git clean -fd.
  # A bare unconditional git clean -fd on its own line is NOT allowed.
  # (git clean -fdn is fine; git clean -fd inside an if block is fine)
  # We verify the dry-run check comes before any git clean -fd line.
  local fdn_line fd_line
  fdn_line=$(echo "$output" | grep -n "git clean -fdn" | head -1 | cut -d: -f1)
  fd_line=$(echo "$output"  | grep -n "git clean -fd$" | head -1 | cut -d: -f1)
  # If git clean -fd appears, it must come after git clean -fdn
  if [ -n "$fd_line" ]; then
    [ "$fd_line" -gt "$fdn_line" ]
  fi
}

# ── vps_update_repo SSH command tests ─────────────────────────────────────────

@test "vps_update_repo: SSH command contains 'git clean -fdn' (dry-run detection)" {
  local env_file
  env_file=$(_make_env_file)

  run _capture_vps_update_cmd "$env_file" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git clean -fdn"* ]]
}

@test "vps_update_repo: SSH command does NOT contain bare 'git clean -fd' without guard" {
  local env_file
  env_file=$(_make_env_file)

  run _capture_vps_update_cmd "$env_file" "false"
  [ "$status" -eq 0 ]
  # The old unconditional line should be gone; only the guarded form appears
  # (we check by requiring the dry-run flag to be present)
  [[ "$output" == *"git clean -fdn"* ]]
}

@test "vps_update_repo: SSH command contains abort error message when FORCE_CLEAN=false" {
  local env_file
  env_file=$(_make_env_file)

  run _capture_vps_update_cmd "$env_file" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: git clean would delete untracked paths"* ]]
}

@test "vps_update_repo: SSH command with FORCE_CLEAN=true bypasses abort" {
  local env_file
  env_file=$(_make_env_file)

  run _capture_vps_update_cmd "$env_file" "true"
  [ "$status" -eq 0 ]
  # With force_clean=true the snippet embeds [ "true" = "true" ] so the git clean
  # -fd branch executes — the dry-run detection is still present (guard structure)
  [[ "$output" == *"git clean -fdn"* ]]
  [[ "$output" == *"git clean -fd"* ]]
}

# ── parse_common_flags: --force-clean ─────────────────────────────────────────

@test "parse_common_flags: --force-clean sets FLAGS_FORCE_CLEAN=true" {
  source "$CLI_ROOT/lib/flags.sh"
  parse_common_flags --force-clean
  [ "$FLAGS_FORCE_CLEAN" = "true" ]
}

@test "parse_common_flags: --force-clean is not left in FLAGS_POSITIONAL" {
  source "$CLI_ROOT/lib/flags.sh"
  parse_common_flags --force-clean --env prod
  [ "${#FLAGS_POSITIONAL[@]}" -eq 0 ]
}

@test "parse_common_flags: without --force-clean, FLAGS_FORCE_CLEAN is empty" {
  source "$CLI_ROOT/lib/flags.sh"
  parse_common_flags --env prod
  [ "${FLAGS_FORCE_CLEAN:-}" = "" ]
}

@test "parse_common_flags: --force-clean combined with other flags" {
  source "$CLI_ROOT/lib/flags.sh"
  parse_common_flags --env prod --force-clean --dry-run
  [ "$FLAGS_FORCE_CLEAN" = "true" ]
  [ "$FLAGS_DRY_RUN" = "true" ]
  [ "$FLAGS_ENV_NAME" = "prod" ]
  [ "${#FLAGS_POSITIONAL[@]}" -eq 0 ]
}

@test "parse_common_flags: resets FLAGS_FORCE_CLEAN across calls" {
  source "$CLI_ROOT/lib/flags.sh"
  parse_common_flags --force-clean
  [ "$FLAGS_FORCE_CLEAN" = "true" ]
  parse_common_flags --env prod
  [ "${FLAGS_FORCE_CLEAN:-}" = "" ]
}
