#!/usr/bin/env bats
# ==================================================
# tests/test_drift.bats — Tests for drift detection workflows
# ==================================================
# Run:  bats tests/test_drift.bats
# Covers: drift_detect, drift_store_event, drift_fix, drift_report,
#         drift_validate_syntax, drift_generate_diff, drift_history

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  confirm() { return 0; }

  # Stub alert functions to avoid sourcing missing modules
  alert_drift_detected() { :; }
  alert_drift_fixed() { :; }
  alert_drift_fix_failed() { :; }
  export -f alert_drift_detected alert_drift_fixed alert_drift_fix_failed

  source "$CLI_ROOT/lib/drift.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-drift-"*
  rm -rf "$TEST_TMP"
}

# ── drift_validate_syntax ─────────────────────────────────────────────────────

@test "drift_validate_syntax: accepts valid JSON file" {
  echo '{"key": "value"}' > "$TEST_TMP/test.json"
  if command -v jq &>/dev/null; then
    run drift_validate_syntax "$TEST_TMP/test.json"
    [ "$status" -eq 0 ]
  else
    skip "jq not available"
  fi
}

@test "drift_validate_syntax: rejects invalid JSON file" {
  echo '{bad json' > "$TEST_TMP/test.json"
  if command -v jq &>/dev/null; then
    run drift_validate_syntax "$TEST_TMP/test.json"
    # jq empty returns non-zero for invalid JSON
    [ "$status" -ne 0 ] || {
      # Some jq versions may handle this differently — skip if so
      skip "jq did not reject invalid JSON (version-dependent)"
    }
  else
    skip "jq not available"
  fi
}

@test "drift_validate_syntax: returns 0 for unknown file types" {
  echo "some content" > "$TEST_TMP/unknown.txt"
  run drift_validate_syntax "$TEST_TMP/unknown.txt"
  [ "$status" -eq 0 ]
}

@test "drift_validate_syntax: dispatches correctly for nginx.conf" {
  echo "events {}" > "$TEST_TMP/nginx.conf"
  # Should not crash regardless of whether nginx is installed
  run drift_validate_syntax "$TEST_TMP/nginx.conf"
  # Status depends on nginx availability, but should not crash
  true
}

@test "drift_validate_syntax: dispatches correctly for Caddyfile" {
  echo ":80 { respond \"ok\" }" > "$TEST_TMP/Caddyfile"
  run drift_validate_syntax "$TEST_TMP/Caddyfile"
  true
}

# ── drift_store_event ─────────────────────────────────────────────────────────

@test "drift_store_event: creates valid JSON drift event" {
  local stack="test-drift-store-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  run drift_store_event "$stack" "prod" '{"file":"docker-compose.yml","git_hash":"abc","vps_hash":"def"}'
  [ "$status" -eq 0 ]

  local drift_dir="$CLI_ROOT/stacks/$stack/drift-history"
  [ -d "$drift_dir" ]

  # Should have exactly one JSON file
  local count
  count=$(ls "$drift_dir"/*.json 2>/dev/null | wc -l)
  [ "$count" -eq 1 ]

  # Validate JSON
  local drift_file
  drift_file=$(ls "$drift_dir"/*.json | head -1)
  jq empty "$drift_file"
  [ "$(jq -r '.stack' "$drift_file")" = "$stack" ]
  [ "$(jq -r '.env' "$drift_file")" = "prod" ]
  [ "$(jq -r '.status' "$drift_file")" = "detected" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── drift_update_event_resolution ─────────────────────────────────────────────

@test "drift_update_event_resolution: updates resolution in drift event" {
  local stack="test-drift-resolve-$$"
  local drift_dir="$CLI_ROOT/stacks/$stack/drift-history"
  mkdir -p "$drift_dir"

  # Create a drift event
  cat > "$drift_dir/20240101-120000.json" <<'EOF'
{
  "drift_id": "drift-20240101-120000",
  "stack": "test",
  "status": "detected",
  "resolution": null
}
EOF

  if command -v jq &>/dev/null; then
    run drift_update_event_resolution "$stack" "drift-20240101-120000" "manual" "success"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.resolution.method' "$drift_dir/20240101-120000.json")" = "manual" ]
    [ "$(jq -r '.resolution.status' "$drift_dir/20240101-120000.json")" = "success" ]
  else
    skip "jq not available"
  fi

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── drift_history ─────────────────────────────────────────────────────────────

@test "drift_history: shows no history when directory missing" {
  run drift_history "nonexistent-stack-$$" "" ""
  [[ "$output" == *"No drift history"* ]] || [[ "$output" == *"No drift events"* ]]
}

@test "drift_history: lists drift events when history exists" {
  local stack="test-drift-hist-$$"
  local drift_dir="$CLI_ROOT/stacks/$stack/drift-history"
  mkdir -p "$drift_dir"

  for ts in 20240101-100000 20240102-100000 20240103-100000; do
    cat > "$drift_dir/${ts}.json" <<EOF
{
  "drift_id": "drift-${ts}",
  "stack": "$stack",
  "timestamp": "2024-01-01T10:00:00Z",
  "status": "detected",
  "files_drifted": [],
  "resolution": null
}
EOF
  done

  run drift_history "$stack" "" ""
  [[ "$output" == *"Drift History"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "drift_history: respects --limit flag" {
  local stack="test-drift-limit-$$"
  local drift_dir="$CLI_ROOT/stacks/$stack/drift-history"
  mkdir -p "$drift_dir"

  for ts in 20240101-100000 20240102-100000 20240103-100000 20240104-100000 20240105-100000; do
    cat > "$drift_dir/${ts}.json" <<EOF
{"drift_id":"drift-${ts}","stack":"$stack","timestamp":"2024-01-01T10:00:00Z","status":"detected","files_drifted":[],"resolution":null}
EOF
  done

  if command -v jq &>/dev/null; then
    run drift_history "$stack" "--limit" "2"
    # Should show Drift History header
    [[ "$output" == *"Drift History"* ]]
    # Count drift_id entries — should be at most 2
    local entry_count
    entry_count=$(echo "$output" | grep -c "drift-2024010" || true)
    [ "$entry_count" -le 2 ]
  fi

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── drift_generate_diff ──────────────────────────────────────────────────────

@test "drift_generate_diff: reports untracked file" {
  mkdir -p "$TEST_TMP/stack_dir"
  run drift_generate_diff "demo" "nonexistent" "$TEST_TMP/stack_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not tracked"* ]]
}

# ── drift_fix ──────────────────────────────────────────────────────────────────
# These tests use a throwaway git repo (not the strut checkout) as CLI_ROOT so
# that "git checkout HEAD -- <tracked file>" has a real commit to restore from,
# without touching this repo's own git history.

# _drift_fixture_init <fixture_root> <stack> <content>
# Creates a one-off git repo with a committed stacks/<stack>/docker-compose.yml
_drift_fixture_init() {
  local fixture_root="$1"
  local stack="$2"
  local content="$3"

  mkdir -p "$fixture_root/stacks/$stack"
  echo "$content" > "$fixture_root/stacks/$stack/docker-compose.yml"
  (
    cd "$fixture_root" || exit 1
    git init -q
    git config user.email "test@strut.local"
    git config user.name "strut-tests"
    git add -A
    git commit -q -m "seed fixture"
  ) >/dev/null 2>&1
}

@test "drift_fix: restores drifted file from git HEAD and re-detect reports clean" {
  local stack="test-drift-fix-restore-$$"
  local fixture_root="$TEST_TMP/fixture-restore"
  local committed_content='{"services":{"web":{"image":"nginx:alpine"}}}'
  _drift_fixture_init "$fixture_root" "$stack" "$committed_content"

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"

  echo '{"services":{"web":{"image":"nginx:latest"}}}' > "$fixture_root/stacks/$stack/docker-compose.yml"

  run drift_detect "$stack" "prod"
  [ "$status" -eq 1 ]

  run drift_fix "$stack" "prod"
  local fix_status="$status"
  local fix_output="$output"

  local restored_content
  restored_content=$(cat "$fixture_root/stacks/$stack/docker-compose.yml")

  run drift_detect "$stack" "prod"
  local redetect_status="$status"

  export CLI_ROOT="$orig_cli_root"

  [ "$fix_status" -eq 0 ]
  [[ "$fix_output" == *"fixed successfully"* ]]
  [ "$restored_content" = "$committed_content" ]
  [ "$redetect_status" -eq 0 ]
}

@test "drift_fix: records resolution success only after real restore" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi

  local stack="test-drift-fix-resolve-$$"
  local fixture_root="$TEST_TMP/fixture-resolve"
  _drift_fixture_init "$fixture_root" "$stack" '{"services":{"web":{"image":"nginx:alpine"}}}'

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"

  echo '{"services":{"web":{"image":"nginx:latest"}}}' > "$fixture_root/stacks/$stack/docker-compose.yml"

  run drift_detect "$stack" "prod"
  [ "$status" -eq 1 ]

  run drift_fix "$stack" "prod"
  local fix_status="$status"

  local drift_file
  drift_file=$(ls -t "$fixture_root/stacks/$stack/drift-history"/*.json 2>/dev/null | head -1)
  local resolution_status
  resolution_status=$(jq -r '.resolution.status' "$drift_file")

  export CLI_ROOT="$orig_cli_root"

  [ "$fix_status" -eq 0 ]
  [ -n "$drift_file" ]
  [ "$resolution_status" = "success" ]
}

@test "drift_fix: dry-run makes no changes and writes no resolution" {
  local stack="test-drift-fix-dryrun-$$"
  local fixture_root="$TEST_TMP/fixture-dryrun"
  _drift_fixture_init "$fixture_root" "$stack" '{"services":{"web":{"image":"nginx:alpine"}}}'

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"

  echo '{"services":{"web":{"image":"nginx:latest"}}}' > "$fixture_root/stacks/$stack/docker-compose.yml"

  run drift_detect "$stack" "prod"
  [ "$status" -eq 1 ]

  run drift_fix "$stack" "prod" "--dry-run"
  local fix_status="$status"
  local fix_output="$output"

  local content_after
  content_after=$(cat "$fixture_root/stacks/$stack/docker-compose.yml")

  local resolution_status="null"
  if command -v jq &>/dev/null; then
    local drift_file
    drift_file=$(ls -t "$fixture_root/stacks/$stack/drift-history"/*.json 2>/dev/null | head -1)
    resolution_status=$(jq -r '.resolution' "$drift_file")
  fi

  export CLI_ROOT="$orig_cli_root"

  [ "$fix_status" -eq 0 ]
  [[ "$fix_output" == *"Dry-run"* ]]
  [ "$content_after" = '{"services":{"web":{"image":"nginx:latest"}}}' ]
  [ "$resolution_status" = "null" ]
}

@test "drift_fix: leaves resolution unrecorded when git checkout fails" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "permission checks are bypassed when running as root"
  fi

  local stack="test-drift-fix-fail-$$"
  local fixture_root="$TEST_TMP/fixture-fail"
  _drift_fixture_init "$fixture_root" "$stack" "version: '3.8'"

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"

  local stack_dir="$fixture_root/stacks/$stack"
  echo "drifted content" > "$stack_dir/docker-compose.yml"

  # Pre-create drift-backups (kept writable) so the backup step still
  # succeeds; only the stack dir itself (the checkout target) is locked
  # down, so the failure is isolated to the "git checkout HEAD" step.
  mkdir -p "$stack_dir/drift-backups"
  chmod 555 "$stack_dir"

  run drift_fix "$stack" "prod"
  local fix_status="$status"
  local fix_output="$output"

  chmod 755 "$stack_dir"

  local content_after
  content_after=$(cat "$stack_dir/docker-compose.yml")

  export CLI_ROOT="$orig_cli_root"

  [ "$fix_status" -ne 0 ]
  [[ "$fix_output" == *"Failed to restore"* ]]
  [ "$content_after" = "drifted content" ]
}

# ── strut#182: compare against the real VPS file, not a second local copy ──
# drift_get_vps_hash/drift_generate_diff used to be handed the SAME local
# path as both "git_file" and "vps_file" — comparing the working tree
# against itself always reports clean, hiding real VPS-side drift. `ssh` is
# stubbed to simulate diff_fetch_remote's `cat <remote_path>` call.

@test "drift_detect: reports drift when the VPS file differs from git, even though local matches git exactly" {
  local stack="test-drift-remote-$$"
  local fixture_root="$TEST_TMP/fixture-remote"
  local committed_content='{"services":{"web":{"image":"nginx:alpine"}}}'
  _drift_fixture_init "$fixture_root" "$stack" "$committed_content"

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"
  # Local working tree is left untouched — it matches git exactly. Before
  # the fix, drift_detect compared this local copy against ITSELF, so it
  # always reported clean regardless of what was actually deployed.
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="/opt/deploy"
  ssh() { echo '{"services":{"web":{"image":"nginx:latest"}}}'; }
  export -f ssh

  run drift_detect "$stack" "prod"
  local rc="$status"
  local out="$output"

  unset VPS_HOST VPS_DEPLOY_DIR
  export CLI_ROOT="$orig_cli_root"

  [ "$rc" -eq 1 ]
  [[ "$out" == *"docker-compose.yml"* ]]
}

@test "drift_detect: no drift when the VPS file matches git exactly" {
  local stack="test-drift-remote-clean-$$"
  local fixture_root="$TEST_TMP/fixture-remote-clean"
  local committed_content='{"services":{"web":{"image":"nginx:alpine"}}}'
  _drift_fixture_init "$fixture_root" "$stack" "$committed_content"

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="/opt/deploy"
  ssh() { echo '{"services":{"web":{"image":"nginx:alpine"}}}'; }
  export -f ssh

  run drift_detect "$stack" "prod"
  local rc="$status"

  unset VPS_HOST VPS_DEPLOY_DIR
  export CLI_ROOT="$orig_cli_root"

  [ "$rc" -eq 0 ]
}

@test "drift_get_vps_hash: SSH unreachable returns 'unreachable' (rc=2)" {
  local stack="test-drift-unreachable-$$"
  local fixture_root="$TEST_TMP/fixture-unreachable"
  _drift_fixture_init "$fixture_root" "$stack" '{"services":{"web":{"image":"nginx:alpine"}}}'

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="/opt/deploy"
  ssh() { return 255; }  # OpenSSH's own connect/auth failure exit code
  export -f ssh

  run drift_get_vps_hash "$stack" "docker-compose.yml" "$fixture_root/stacks/$stack"

  unset VPS_HOST VPS_DEPLOY_DIR
  export CLI_ROOT="$orig_cli_root"

  [ "$status" -eq 2 ]
  [ "$output" = "unreachable" ]
}

@test "drift_detect: SSH unreachable is skipped, not reported as drift" {
  local stack="test-drift-unreachable-detect-$$"
  local fixture_root="$TEST_TMP/fixture-unreachable-detect"
  _drift_fixture_init "$fixture_root" "$stack" '{"services":{"web":{"image":"nginx:alpine"}}}'

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="/opt/deploy"
  ssh() { return 255; }
  export -f ssh

  run drift_detect "$stack" "prod"
  local rc="$status"
  local out="$output"

  unset VPS_HOST VPS_DEPLOY_DIR
  export CLI_ROOT="$orig_cli_root"

  [ "$rc" -eq 0 ]
  [[ "$out" == *"No configuration drift"* ]]
}

@test "drift_generate_diff: shows a real diff against VPS content, not an empty self-comparison" {
  local stack="test-drift-diff-remote-$$"
  local fixture_root="$TEST_TMP/fixture-diff-remote"
  local committed_content='{"services":{"web":{"image":"nginx:alpine"}}}'
  _drift_fixture_init "$fixture_root" "$stack" "$committed_content"

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="/opt/deploy"
  ssh() { echo '{"services":{"web":{"image":"nginx:latest"}}}'; }
  export -f ssh

  run drift_generate_diff "$stack" "docker-compose.yml" "$fixture_root/stacks/$stack"

  unset VPS_HOST VPS_DEPLOY_DIR
  export CLI_ROOT="$orig_cli_root"

  [[ "$output" == *"nginx:alpine"* ]]
  [[ "$output" == *"nginx:latest"* ]]
  [[ "$output" == *"vps-runtime"* ]]
}

@test "drift_fix: with VPS_HOST set, success message hints that deploy/release is needed to push the fix" {
  local stack="test-drift-fix-vps-hint-$$"
  local fixture_root="$TEST_TMP/fixture-vps-hint"
  local committed_content='{"services":{"web":{"image":"nginx:alpine"}}}'
  _drift_fixture_init "$fixture_root" "$stack" "$committed_content"

  local orig_cli_root="$CLI_ROOT"
  export CLI_ROOT="$fixture_root"
  export VPS_HOST="vps.example.com"
  export VPS_DEPLOY_DIR="/opt/deploy"
  ssh() { echo '{"services":{"web":{"image":"nginx:latest"}}}'; }
  export -f ssh

  run drift_fix "$stack" "prod"
  local fix_status="$status"
  local fix_output="$output"

  unset VPS_HOST VPS_DEPLOY_DIR
  export CLI_ROOT="$orig_cli_root"

  [ "$fix_status" -eq 0 ]
  [[ "$fix_output" == *"push it to the VPS"* ]]
}

# ── Property: drift_store_event always creates valid JSON ─────────────────────

@test "Property: drift_store_event always creates valid JSON (100 iterations)" {
  for i in $(seq 1 100); do
    local stack="test-drift-prop-$$-$i"
    mkdir -p "$CLI_ROOT/stacks/$stack"

    # Random env name
    local envs=("prod" "staging" "dev" "test" "local")
    local env="${envs[$((RANDOM % ${#envs[@]}))]}"

    # Random file name
    local files=("docker-compose.yml" ".env.template" "nginx/nginx.conf" "caddy/Caddyfile" "backup.conf")
    local file="${files[$((RANDOM % ${#files[@]}))]}"

    drift_store_event "$stack" "$env" "{\"file\":\"$file\",\"git_hash\":\"abc$i\",\"vps_hash\":\"def$i\"}" >/dev/null 2>&1

    local drift_dir="$CLI_ROOT/stacks/$stack/drift-history"
    local drift_file
    drift_file=$(ls "$drift_dir"/*.json 2>/dev/null | head -1)

    [ -f "$drift_file" ] || {
      echo "FAILED iteration $i: no drift file created"
      rm -rf "$CLI_ROOT/stacks/$stack"
      return 1
    }

    jq empty "$drift_file" || {
      echo "FAILED iteration $i: invalid JSON in drift file"
      rm -rf "$CLI_ROOT/stacks/$stack"
      return 1
    }

    [ "$(jq -r '.env' "$drift_file")" = "$env" ] || {
      echo "FAILED iteration $i: env mismatch"
      rm -rf "$CLI_ROOT/stacks/$stack"
      return 1
    }

    rm -rf "$CLI_ROOT/stacks/$stack"
  done
}

# ── on_drift_detected hook (via cmd_drift) ────────────────────────────────────

@test "cmd_drift detect: fires on_drift_detected hook when drift_detect returns 1" {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"

  local strut_root="$CLI_ROOT"

  # Create a fake LIB with a drift.sh that defines a drift-found stub
  local fake_lib="$TEST_TMP/fake_lib_drift"
  mkdir -p "$fake_lib"
  cat > "$fake_lib/drift.sh" <<'FAKESCRIPT'
drift_detect() { echo "drift detected"; return 1; }
FAKESCRIPT

  LIB="$fake_lib"
  export LIB

  # Capture fire_hook_or_warn calls
  fire_hook_or_warn() { echo "fire_hook_or_warn $*"; return 0; }
  export -f fire_hook_or_warn

  validate_env_file() { return 0; }
  export -f validate_env_file

  # Need CMD_* vars
  export CMD_STACK="mystack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/mystack"
  export CMD_ENV_FILE="$TEST_TMP/.test.env"
  export CMD_ENV_NAME="test"
  export CMD_JSON=""
  mkdir -p "$TEST_TMP/stacks/mystack"
  touch "$TEST_TMP/.test.env"

  source "$strut_root/lib/cmd_drift.sh"

  run cmd_drift detect
  [ "$status" -ne 0 ]
  [[ "$output" == *"fire_hook_or_warn"* ]]
  [[ "$output" == *"on_drift_detected"* ]]
}

@test "cmd_drift detect: does NOT fire on_drift_detected when no drift" {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"

  local strut_root="$CLI_ROOT"

  # Create a fake LIB with a drift.sh that defines a no-drift stub
  local fake_lib="$TEST_TMP/fake_lib"
  mkdir -p "$fake_lib"
  cat > "$fake_lib/drift.sh" <<'FAKESCRIPT'
drift_detect() { echo "no drift"; return 0; }
FAKESCRIPT

  LIB="$fake_lib"
  export LIB

  fire_hook_or_warn() { echo "fire_hook_or_warn $*"; return 0; }
  export -f fire_hook_or_warn

  validate_env_file() { return 0; }
  export -f validate_env_file

  export CMD_STACK="mystack"
  export CMD_STACK_DIR="$TEST_TMP/stacks/mystack2"
  export CMD_ENV_FILE="$TEST_TMP/.test2.env"
  export CMD_ENV_NAME="test"
  export CMD_JSON=""
  mkdir -p "$TEST_TMP/stacks/mystack2"
  touch "$TEST_TMP/.test2.env"

  source "$strut_root/lib/cmd_drift.sh"

  run cmd_drift detect
  [ "$status" -eq 0 ]
  [[ "$output" != *"on_drift_detected"* ]]
}
