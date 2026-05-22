#!/usr/bin/env bats
# ==================================================
# tests/test_github_token.bats — Tests for lib/github-token.sh
# ==================================================
# Run:  bats tests/test_github_token.bats
# Covers: github_check_token_permissions, github_create_fine_grained_token
#         (with stubbed gh CLI)

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  # Color vars needed by github-token.sh
  export BLUE="" NC="" GREEN="" RED="" YELLOW=""

  source "$CLI_ROOT/lib/github-token.sh"
}

teardown() { common_teardown; }

# ── github_check_token_permissions ────────────────────────────────────────────

@test "github_check_token_permissions: returns not_installed when gh missing" {
  # Override command to simulate gh not being installed
  command() {
    if [[ "$2" == "gh" ]]; then return 1; fi
    builtin command "$@"
  }
  export -f command

  run github_check_token_permissions
  [ "$status" -eq 1 ]
  [ "$output" = "not_installed" ]
}

@test "github_check_token_permissions: returns not_authenticated when gh auth fails" {
  # Stub gh to exist but fail on auth
  gh() {
    case "$1" in
      auth) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  run github_check_token_permissions
  [ "$status" -eq 1 ]
  [ "$output" = "not_authenticated" ]
}

@test "github_check_token_permissions: returns has_permissions when API succeeds" {
  gh() {
    case "$1" in
      auth) return 0 ;;
      api) return 0 ;;
    esac
  }
  export -f gh

  run github_check_token_permissions
  [ "$status" -eq 0 ]
  [ "$output" = "has_permissions" ]
}

@test "github_check_token_permissions: returns missing_permissions when API fails" {
  gh() {
    case "$1" in
      auth) return 0 ;;
      api) return 1 ;;
    esac
  }
  export -f gh

  run github_check_token_permissions
  [ "$status" -eq 1 ]
  [ "$output" = "missing_permissions" ]
}

# ── github_create_fine_grained_token ──────────────────────────────────────────

@test "github_create_fine_grained_token: fails without vps_host" {
  run github_create_fine_grained_token "" "owner" "repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "github_create_fine_grained_token: fails without repo_owner" {
  unset DEFAULT_ORG
  run github_create_fine_grained_token "my-vps" "" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEFAULT_ORG"* ]] || [[ "$output" == *"--org"* ]]
}

@test "github_create_fine_grained_token: fails when gh not installed" {
  # Override command to simulate gh not being installed
  command() {
    if [[ "$2" == "gh" ]]; then return 1; fi
    builtin command "$@"
  }
  export -f command

  run github_create_fine_grained_token "my-vps" "owner" "repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "github_create_fine_grained_token: fails when gh not authenticated" {
  gh() {
    case "$1" in
      auth) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  run github_create_fine_grained_token "my-vps" "owner" "repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not authenticated"* ]]
}

@test "github_create_fine_grained_token: fails when repo not found" {
  gh() {
    case "$1" in
      auth) return 0 ;;
      api)
        # Simulate repo not found (empty output)
        echo ""
        return 1
        ;;
    esac
  }
  export -f gh

  run github_create_fine_grained_token "my-vps" "owner" "repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not get repository ID"* ]]
}

# ── github_list_fine_grained_tokens ───────────────────────────────────────────

@test "github_list_fine_grained_tokens: fails when gh not installed" {
  command() {
    if [[ "$2" == "gh" ]]; then return 1; fi
    builtin command "$@"
  }
  export -f command

  run github_list_fine_grained_tokens
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "github_list_fine_grained_tokens: fails when gh not authenticated" {
  gh() {
    case "$1" in
      auth) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  run github_list_fine_grained_tokens
  [ "$status" -ne 0 ]
  [[ "$output" == *"not authenticated"* ]]
}

# ── github_revoke_token ───────────────────────────────────────────────────────

@test "github_revoke_token: fails without token_id" {
  # Use real fail() (exit 1) in the run subshell so the function aborts
  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run github_revoke_token ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "github_revoke_token: fails when gh not installed" {
  command() {
    if [[ "$2" == "gh" ]]; then return 1; fi
    builtin command "$@"
  }
  export -f command

  run github_revoke_token "12345"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
}
