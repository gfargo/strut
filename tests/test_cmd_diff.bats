#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_diff.bats — Tests for `strut <stack> diff`
# ==================================================
# Focus: SSH fetch failure (OSS-435) must surface as "error fetching remote
# state" (exit 2), not a false pending-ADD diff + destructive-changes banner.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers so we can assert on plain text output.
  fail()  { echo "FAIL: $1" >&2; return 1; }
  ok()    { echo "OK: $*"; }
  warn()  { echo "WARN: $*" >&2; }
  log()   { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  export -f fail ok warn log error

  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/diff.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"
  source "$CLI_ROOT/lib/cmd_diff.sh"

  # Stub SSH plumbing — real diff_fetch_remote is used, but we stub `ssh`
  # itself so tests control whether it's a fetch failure or a missing file.
  build_ssh_opts() { echo "-o BatchMode=yes"; }
  export -f build_ssh_opts

  mkdir -p "$TEST_TMP/stacks/test-stack"
  cat > "$TEST_TMP/stacks/test-stack/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx:1.0
EOF
  cat > "$TEST_TMP/.prod.env" <<'EOF'
VPS_HOST=example.com
FOO=bar
EOF

  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$TEST_TMP/.prod.env"
  export CMD_ENV_NAME="prod"
  export CMD_JSON="false"
  export CLI_ROOT="$CLI_ROOT"
}

teardown() {
  common_teardown
}

@test "cmd_diff: SSH failure on env fetch exits 2 with no destructive banner" {
  ssh() { return 255; }
  export -f ssh

  run cmd_diff
  [ "$status" -eq 2 ]
  [[ "$output" == *"error fetching remote state"* ]] || [[ "$output" == *"Error fetching remote state"* ]]
  [[ "$output" != *"DATA-DESTRUCTIVE"* ]]
  [[ "$output" != *"Pending changes for"* ]]
}

@test "cmd_diff: SSH failure on compose fetch (env fetch ok) exits 2 with no destructive banner" {
  # First diff_fetch_remote call (env) succeeds via `cat` returning nothing
  # (ssh "succeeds" per stub), second call (compose) fails via ssh_exit=255.
  local calls="$TEST_TMP/ssh_calls"
  : > "$calls"
  ssh() {
    local n
    n=$(wc -l < "$calls")
    echo "" >> "$calls"
    if [ "$n" -eq 0 ]; then
      return 0
    fi
    return 255
  }
  export -f ssh

  run cmd_diff
  [ "$status" -eq 2 ]
  [[ "$output" == *"error fetching remote state"* ]] || [[ "$output" == *"Error fetching remote state"* ]]
  [[ "$output" != *"DATA-DESTRUCTIVE"* ]]
}

@test "cmd_diff: genuinely missing remote files still produce a destructive banner (regression guard)" {
  # ssh "succeeds" (host reachable) but `cat` on the remote finds nothing —
  # this must NOT be treated as a fetch error.
  ssh() { return 0; }
  export -f ssh

  cat > "$TEST_TMP/stacks/test-stack/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx:1.0
    volumes:
      - data:/var/lib/data
volumes:
  data:
EOF

  run cmd_diff
  [ "$status" -eq 1 ]
  [[ "$output" == *"Pending changes for"* ]]
}

@test "cmd_diff: no changes exits 0" {
  ssh() { return 0; }
  export -f ssh

  # Make remote content match local exactly by echoing local file content.
  diff_fetch_remote() {
    case "$1" in
      *.env) cat "$TEST_TMP/.prod.env" ;;
      *docker-compose.yml) cat "$TEST_TMP/stacks/test-stack/docker-compose.yml" ;;
    esac
  }
  export -f diff_fetch_remote

  run cmd_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes"* ]]
}
