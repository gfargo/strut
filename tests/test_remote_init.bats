#!/usr/bin/env bats
# ==================================================
# tests/test_remote_init.bats — Tests for lib/cmd_remote_init.sh
# ==================================================
# Run:  bats tests/test_remote_init.bats
# Covers: _usage_remote_init, cmd_remote_init dry-run mode,
#         argument parsing, connection resolution

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  source "$CLI_ROOT/lib/output.sh"
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "BANNER: $*"; }
  run_cmd() { echo "RUN: $*"; }
  export -f fail ok warn log error print_banner run_cmd

  # Stub build_ssh_opts
  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  export -f build_ssh_opts

  # Stub git to return a fake remote URL
  git() {
    case "$1" in
      remote) echo "https://github.com/gfargo/strut.git" ;;
      *) command git "$@" ;;
    esac
  }
  export -f git

  source "$CLI_ROOT/lib/cmd_remote_init.sh"
}

teardown() { common_teardown; }

# ── Usage ─────────────────────────────────────────────────────────────────────

@test "_usage_remote_init: prints usage information" {
  run _usage_remote_init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--env"* ]]
  [[ "$output" == *"--host"* ]]
  [[ "$output" == *"--user"* ]]
  [[ "$output" == *"--key"* ]]
  [[ "$output" == *"--port"* ]]
  [[ "$output" == *"--repo"* ]]
  [[ "$output" == *"--branch"* ]]
  [[ "$output" == *"--deploy-dir"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "_usage_remote_init: includes examples" {
  run _usage_remote_init
  [ "$status" -eq 0 ]
  [[ "$output" == *"Examples:"* ]]
  [[ "$output" == *"remote:init"* ]]
}

@test "_usage_remote_init: describes what it does" {
  run _usage_remote_init
  [ "$status" -eq 0 ]
  [[ "$output" == *"What this does:"* ]]
  [[ "$output" == *"SSH connectivity"* ]]
  [[ "$output" == *"Clones"* ]]
}

# ── Dry-run mode ──────────────────────────────────────────────────────────────

@test "cmd_remote_init: dry-run shows execution plan" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]
}

@test "cmd_remote_init: dry-run shows SSH connectivity test" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH connectivity"* ]] || [[ "$output" == *"ssh"* ]]
}

@test "cmd_remote_init: dry-run shows clone step" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Clone"* ]] || [[ "$output" == *"clone"* ]] || [[ "$output" == *"git"* ]]
}

@test "cmd_remote_init: dry-run uses custom port" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --port 2222 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"2222"* ]]
}

@test "cmd_remote_init: dry-run uses custom branch" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --branch "develop" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"develop"* ]]
}

@test "cmd_remote_init: dry-run uses custom deploy-dir" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --deploy-dir "/opt/strut" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"/opt/strut"* ]]
}

@test "cmd_remote_init: dry-run uses custom repo URL" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --repo "https://github.com/other/repo.git" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"other/repo"* ]]
}

@test "cmd_remote_init: --dry-run prevents real ssh execution even when global DRY_RUN is unset" {
  # Regression test: this file's setup() stubs run_cmd() to a plain echo, so
  # every other dry-run test above never actually exercises run_cmd's own
  # DRY_RUN gate (lib/utils.sh:161). Reinstate the real run_cmd here so this
  # test proves --dry-run alone (with the global DRY_RUN unset/false, i.e.
  # the top-level `strut remote:init --host ... --dry-run` path) is enough
  # to stop the real ssh calls, per cmd_remote_init's own DRY_RUN sync at
  # lib/cmd_remote_init.sh:68-77.
  unset DRY_RUN
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run_cmd() {
    local desc="$1"; shift
    if [ "$DRY_RUN" = "true" ]; then
      echo "[DRY-RUN] $desc: $*"
      return 0
    else
      "$@"
    fi
  }
  export -f run_cmd

  local marker="$TEST_TMP/ssh_was_called"
  ssh() { touch "$marker"; echo "SHOULD NOT RUN FOR REAL: $*"; }
  export -f ssh

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ ! -f "$marker" ]
}

# ── Error cases ───────────────────────────────────────────────────────────────

@test "cmd_remote_init: fails without host" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""
  unset VPS_HOST

  # Use exit-based fail in run subshell
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_remote_init --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"VPS_HOST"* ]] || [[ "$output" == *"--host"* ]]
}

@test "cmd_remote_init: resolves host from env file" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"

  # Create a test env file
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=from-env.example.com
VPS_USER=envuser
VPS_PORT=2222
EOF
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"

  run cmd_remote_init --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"from-env.example.com"* ]]
  [[ "$output" == *"envuser"* ]]
}

@test "cmd_remote_init: CLI flags override env file values" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"

  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=from-env.example.com
VPS_USER=envuser
EOF
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"

  run cmd_remote_init --host "override.local" --user "cliuser" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"override.local"* ]]
  [[ "$output" == *"cliuser"* ]]
}

@test "cmd_remote_init: detects repo URL from git remote" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com/gfargo/strut"* ]]
}

@test "cmd_remote_init: defaults user to ubuntu" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""
  unset VPS_USER

  run cmd_remote_init --host "10.0.0.1" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ubuntu"* ]]
}

@test "cmd_remote_init: preserves dispatcher-resolved VPS_HOST over env file value" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export VPS_HOST="standby-host.internal"

  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=primary-host.internal
EOF
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"

  run cmd_remote_init --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"standby-host.internal"* ]]
  [[ "$output" != *"primary-host.internal"* ]]
}

@test "cmd_remote_init: defaults branch to main" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  export CMD_ENV_FILE=""

  run cmd_remote_init --host "10.0.0.1" --user "deploy" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]]
}

# ── "Already initialized" branch (real, non-dry-run SSH flow) ─────────────────

@test "cmd_remote_init: already-initialized directory with working strut reports success" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=existing.example.com
VPS_USER=deploy
EOF
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"

  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"echo ok"*) echo "ok" ;;
      *"test -d"*".git"*) return 0 ;;
      *"chmod +x"*) return 0 ;;
      *"--version"*) echo "0.35.2" ;;
      *"rev-parse --abbrev-ref HEAD"*) echo "main" ;;
      *) return 0 ;;
    esac
  }
  export -f ssh

  run cmd_remote_init
  [ "$status" -eq 0 ]
  [[ "$output" == *"already initialized"* ]]
  [[ "$output" == *"0.35.2"* ]]
}

@test "cmd_remote_init: already-initialized directory with broken strut binary fails clearly" {
  export DRY_RUN=false
  export CMD_STACK="my-stack"
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=existing.example.com
VPS_USER=deploy
EOF
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"

  # Use exit-based fail so the run subshell actually stops here, matching
  # the "fails without host" test above.
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"echo ok"*) echo "ok" ;;
      *"test -d"*".git"*) return 0 ;;
      *"chmod +x"*) return 1 ;;
      *"--version"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f ssh

  run cmd_remote_init
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or broken"* ]]
  [[ "$output" != *"already initialized on"* ]]
}
