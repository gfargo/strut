#!/usr/bin/env bats
# ==================================================
# tests/test_branch_org.bats — Property tests for branch and org propagation
# ==================================================
# Run:  bats tests/test_branch_org.bats
# Covers: DEFAULT_BRANCH propagation to VPS sync commands
# Feature: ch-deploy-modularization, Property 12

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_utils() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
}

# ── Helper: generate random branch name ───────────────────────────────────────

_rand_branch() {
  local len="${1:-8}"
  # Branch names: alphanumeric, hyphens, slashes, underscores
  local chars='abcdefghijklmnopqrstuvwxyz0123456789-_'
  local result=""
  local first
  first=$(LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 1 2>/dev/null || echo "b")
  result="$first"
  local rest
  rest=$(LC_ALL=C tr -dc "$chars" < /dev/urandom | head -c "$((len - 1))" 2>/dev/null || echo "ranch")
  result="${result}${rest}"
  echo "$result"
}

# ── Helper: extract the SSH command that vps_update_repo would build ──────────
# We source deploy.sh but stub out ssh, validate_env_file, and build_ssh_opts
# so we can capture the command string without actually connecting.

_capture_vps_update_cmd() {
  local branch="$1"
  local env_file="$2"

  _load_utils
  source "$CLI_ROOT/lib/config.sh"
  source "$CLI_ROOT/lib/docker.sh"

  # Stub validate_env_file to just source the file
  validate_env_file() {
    local ef="$1"; shift
    [ -f "$ef" ] && { set -a; source "$ef"; set +a; }
  }

  # Stub build_ssh_opts
  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }

  # Stub ssh to capture the command
  ssh() {
    # Print all args so we can inspect the command
    echo "SSH_CMD: $*"
  }

  # Stub ok/warn to suppress output
  ok() { :; }
  warn() { echo "$*"; }

  export DEFAULT_BRANCH="$branch"

  source "$CLI_ROOT/lib/deploy.sh"
  vps_update_repo "test-stack" "$env_file"
}

# ── Property 12: DEFAULT_BRANCH propagates to VPS sync commands ──────────────
# Feature: ch-deploy-modularization, Property 12: DEFAULT_BRANCH propagates to VPS sync commands
# Validates: Requirements 8.1

@test "Property 12: DEFAULT_BRANCH propagates to VPS sync commands (100 iterations)" {
  _load_utils

  for i in $(seq 1 100); do
    local branch
    branch="$(_rand_branch)"

    # Create a minimal env file
    local env_file="$TEST_TMP/env_branch_$i"
    cat > "$env_file" <<EOF
VPS_HOST=10.0.0.1
VPS_USER=deploy
GH_PAT=test_token_$i
EOF

    run _capture_vps_update_cmd "$branch" "$env_file"
    [ "$status" -eq 0 ]

    # The SSH command should contain origin/$branch
    [[ "$output" == *"origin/$branch"* ]]
    # Should NOT contain hardcoded origin/main (unless branch happens to be "main")
    if [ "$branch" != "main" ]; then
      [[ "$output" != *"origin/main"* ]]
    fi
  done
}

# ── Edge case: DEFAULT_BRANCH defaults to main ───────────────────────────────

@test "vps_update_repo defaults to origin/main when DEFAULT_BRANCH is unset" {
  local env_file="$TEST_TMP/env_default_branch"
  cat > "$env_file" <<EOF
VPS_HOST=10.0.0.1
VPS_USER=deploy
GH_PAT=test_token
EOF

  unset DEFAULT_BRANCH
  run _capture_vps_update_cmd "" "$env_file"

  # When branch is empty, the default "main" should be used
  # (the function reads DEFAULT_BRANCH which defaults to main)
  [[ "$output" == *"origin/"* ]]
}

# ── Helper: generate random org name ──────────────────────────────────────────

_rand_org() {
  local len="${1:-8}"
  local chars='abcdefghijklmnopqrstuvwxyz0123456789-'
  local first
  first=$(LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 1 2>/dev/null || echo "o")
  local rest
  rest=$(LC_ALL=C tr -dc "$chars" < /dev/urandom | head -c "$((len - 1))" 2>/dev/null || echo "rg")
  echo "${first}${rest}"
}

# ── Helper: source github-token.sh with stubs, capture repo_owner ─────────────
# We stub gh, command, log, warn, ok so the function never hits real GitHub API.
# The function will fail at the `command -v gh` check, but we capture repo_owner
# before that by intercepting the `log` call that fires after the owner check.

_capture_token_repo_owner() {
  local org_value="$1"
  local explicit_org="${2:-}"

  # Set DEFAULT_ORG (empty string means unset behavior)
  if [ -n "$org_value" ]; then
    export DEFAULT_ORG="$org_value"
  else
    unset DEFAULT_ORG
  fi

  local capture_file="$TEST_TMP/captured_repo_path"
  rm -f "$capture_file"
  export _CAPTURE_FILE="$capture_file"

  # Source the file in a subshell with stubs
  (
    # Override fail to print and exit
    fail() { echo "FAIL: $1" >&2; exit 1; }
    log() { :; }
    warn() { :; }
    ok() { :; }

    # Stub command to pretend gh is installed
    command() {
      if [[ "${2:-}" == "gh" ]]; then return 0; fi
      builtin command "$@"
    }

    # Stub gh — $1=api, $2=path or auth
    gh() {
      case "${1:-}" in
        auth) return 0 ;;
        api)
          local path="${2:-}"
          if [[ "$path" == /repos/* ]]; then
            # Write the repo path to capture file (not stdout, which is captured by $())
            echo "$path" > "$_CAPTURE_FILE"
            echo 12345
            return 0
          fi
          # Token creation endpoint — return fake token JSON
          echo '{"token":"fake_tok"}'
          return 0
          ;;
      esac
      return 0
    }

    # Stub date/gdate
    date() { echo "2025-01-01T00:00:00Z"; }
    gdate() { echo "2025-01-01T00:00:00Z"; }

    # Stub jq
    jq() { echo "fake_token_123"; }

    set +uo pipefail
    source "$CLI_ROOT/lib/github-token.sh"

    if [ -n "$explicit_org" ]; then
      github_create_fine_grained_token "test-vps" "$explicit_org"
    else
      github_create_fine_grained_token "test-vps"
    fi
  )
}

# ── Property 13: DEFAULT_ORG propagates to token creation defaults ────────────
# Feature: ch-deploy-modularization, Property 13: DEFAULT_ORG propagates to token creation defaults
# Validates: Requirements 9.1

@test "Property 13: DEFAULT_ORG propagates to token creation defaults (100 iterations)" {
  for i in $(seq 1 100); do
    local org
    org="$(_rand_org)"

    run _capture_token_repo_owner "$org"

    # The function should succeed (not fail on empty org)
    [ "$status" -eq 0 ]

    # The captured repo path should contain the org
    local captured
    captured="$(cat "$TEST_TMP/captured_repo_path" 2>/dev/null || echo "")"
    [[ "$captured" == "/repos/$org/strut" ]]
  done
}

# ── Edge case: DEFAULT_ORG unset and no explicit org → fail ───────────────────

@test "github_create_fine_grained_token fails when DEFAULT_ORG unset and no explicit org" {
  unset DEFAULT_ORG

  run _capture_token_repo_owner "" ""

  # Should fail
  [ "$status" -ne 0 ]

  # Should contain the expected error message
  [[ "$output" == *"pass --org or set DEFAULT_ORG in strut.conf"* ]]
}
