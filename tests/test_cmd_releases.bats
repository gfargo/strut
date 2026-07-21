#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_releases.bats — Tests for `strut <stack> releases`
# ==================================================
# Run:  bats tests/test_cmd_releases.bats
# Covers OSS-261: deploy history / audit trail, integrated with rollback
# ref resolution (releases share the rollback snapshot ID space).

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/history.sh"
  source "$CLI_ROOT/lib/rollback.sh"
  source "$CLI_ROOT/lib/cmd_releases.sh"

  export LIB="$CLI_ROOT/lib"

  mkdir -p "$TEST_TMP/stacks/test-stack"
  export CLI_ROOT="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP"
}

teardown() { common_teardown; }

_set_releases_ctx() {
  local env_file="$1"
  export CMD_STACK="test-stack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/test-stack"
  export CMD_ENV_FILE="$env_file"
  export CMD_ENV_NAME="test"
  export DRY_RUN=false
}

# Write a rollback snapshot at $CMD_STACK_DIR/.rollback/<id>.json with the
# given service=image pairs (mirrors _write_snap in test_rollback_diff.bats).
_write_release_snapshot() {
  local id="$1"; shift
  local dir="$TEST_TMP/stacks/test-stack/.rollback"
  mkdir -p "$dir"
  local services="{" first=true
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    if $first; then first=false; else services+=","; fi
    services+="\"$key\":{\"image\":\"$val\"}"
  done
  services+="}"
  cat > "$dir/$id.json" <<EOF
{
  "timestamp": "2026-04-20T09:00:00Z",
  "stack": "test-stack",
  "env": "test",
  "service_count": $#,
  "services": $services
}
EOF
}

_require_jq() {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

# ── Remote dispatch ───────────────────────────────────────────────────────────

@test "cmd_releases: dispatches remotely for a VPS-mapped stack" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.internal
EOF

  should_dispatch_remote() { return 0; }
  run_remote_strut() { echo "run_remote_strut $*"; }
  export -f should_dispatch_remote run_remote_strut

  _set_releases_ctx "$TEST_TMP/.test.env"

  run cmd_releases
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_remote_strut test-stack test releases --limit 10"* ]]
}

@test "cmd_releases: 'show <id>' is forwarded to the remote dispatch" {
  cat > "$TEST_TMP/.test.env" <<'EOF'
VPS_HOST=vps.example.internal
EOF

  should_dispatch_remote() { return 0; }
  run_remote_strut() { echo "run_remote_strut $*"; }
  export -f should_dispatch_remote run_remote_strut

  _set_releases_ctx "$TEST_TMP/.test.env"

  run cmd_releases show HEAD --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_remote_strut test-stack test releases show HEAD --json"* ]]
}

# ── Local list ────────────────────────────────────────────────────────────────

@test "cmd_releases: reports no releases for a stack that's never deployed" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  _set_releases_ctx ""

  run cmd_releases
  [ "$status" -eq 0 ]
  [[ "$output" == *"No releases recorded yet."* ]]
}

@test "cmd_releases: lists deploy/release entries newest-first with mode + SHA" {
  _require_jq
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  history_record "$TEST_TMP/stacks/test-stack" "deploy" "success" "env=test" "mode=standard" "git_sha=abc1234" "release_id=20260420-090000"
  sleep 1
  history_record "$TEST_TMP/stacks/test-stack" "rollback" "success" "env=test" "snapshot=20260420-090000"
  sleep 1
  history_record "$TEST_TMP/stacks/test-stack" "deploy" "success" "env=test" "mode=blue-green" "git_sha=def5678" "release_id=20260420-100000"

  _set_releases_ctx ""

  run cmd_releases
  [ "$status" -eq 0 ]
  # rollback entries are excluded from the release-centric view
  [[ "$output" != *"rollback"* ]]
  [[ "$output" == *"blue-green"* ]]
  [[ "$output" == *"def5678"* ]]

  # newest (blue-green/def5678) appears before the oldest (standard/abc1234)
  local newest_line oldest_line
  newest_line=$(echo "$output" | grep -n "def5678" | head -1 | cut -d: -f1)
  oldest_line=$(echo "$output" | grep -n "abc1234" | head -1 | cut -d: -f1)
  [ "$newest_line" -lt "$oldest_line" ]
}

@test "cmd_releases --json: emits a parseable JSON array of deploy/release entries only" {
  _require_jq
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  history_record "$TEST_TMP/stacks/test-stack" "deploy" "success" "env=test" "mode=standard" "release_id=20260420-090000"
  history_record "$TEST_TMP/stacks/test-stack" "rollback" "success" "env=test" "snapshot=20260420-090000"

  _set_releases_ctx ""

  run cmd_releases --json
  [ "$status" -eq 0 ]
  echo "$output" > "$TEST_TMP/out.json"
  run jq -e 'length == 1' "$TEST_TMP/out.json"
  [ "$status" -eq 0 ]
}

# ── show ──────────────────────────────────────────────────────────────────────

@test "cmd_releases show: errors cleanly when no <id> is given" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  _set_releases_ctx ""

  run cmd_releases show
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires an <id>"* ]]
}

@test "cmd_releases show <id>: prints full detail including mode, SHA, and image tags" {
  _require_jq
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  history_record "$TEST_TMP/stacks/test-stack" "deploy" "success" "env=test" "mode=standard" "git_sha=abc1234" "release_id=20260420-090000"
  _write_release_snapshot "20260420-090000" "web=myorg/web:1.2.3" "worker=myorg/worker:1.2.3"

  _set_releases_ctx ""

  run cmd_releases show 20260420-090000
  [ "$status" -eq 0 ]
  [[ "$output" == *"abc1234"* ]]
  [[ "$output" == *"standard"* ]]
  [[ "$output" == *"myorg/web:1.2.3"* ]]
}

@test "cmd_releases show HEAD: resolves to the newest snapshot via rollback_resolve_ref" {
  _require_jq
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  history_record "$TEST_TMP/stacks/test-stack" "deploy" "success" "env=test" "mode=standard" "git_sha=abc1234" "release_id=20260420-090000"
  _write_release_snapshot "20260420-090000" "web=myorg/web:1.2.3"
  sleep 1
  history_record "$TEST_TMP/stacks/test-stack" "deploy" "success" "env=test" "mode=blue-green" "git_sha=def5678" "release_id=20260420-100000"
  _write_release_snapshot "20260420-100000" "web=myorg/web:1.3.0"

  _set_releases_ctx ""

  run cmd_releases show HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"def5678"* ]]
  [[ "$output" == *"myorg/web:1.3.0"* ]]
}

@test "cmd_releases show <unknown-id>: fails cleanly" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  _set_releases_ctx ""

  run cmd_releases show does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"No release found"* ]]
}

@test "cmd_releases show <id> --json: emits a JSON object with a rollback_images array" {
  _require_jq
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  history_record "$TEST_TMP/stacks/test-stack" "deploy" "success" "env=test" "mode=standard" "git_sha=abc1234" "release_id=20260420-090000"
  _write_release_snapshot "20260420-090000" "web=myorg/web:1.2.3"

  _set_releases_ctx ""

  run cmd_releases show 20260420-090000 --json
  [ "$status" -eq 0 ]
  echo "$output" > "$TEST_TMP/show.json"
  run jq -e '.git_sha == "abc1234" and (.rollback_images | length) == 1' "$TEST_TMP/show.json"
  [ "$status" -eq 0 ]
}

@test "cmd_releases show --json: --json is not swallowed as the <id>" {
  should_dispatch_remote() { return 1; }
  export -f should_dispatch_remote

  _set_releases_ctx ""

  run cmd_releases show --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires an <id>"* ]]
}
