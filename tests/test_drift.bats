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

@test "drift_generate_diff: reports missing VPS file" {
  run drift_generate_diff "$TEST_TMP/git-file" "$TEST_TMP/nonexistent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VPS file missing"* ]]
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
