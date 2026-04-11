#!/usr/bin/env bats
# ==================================================
# tests/test_rollback.bats — Tests for deploy rollback
# ==================================================
# Run:  bats tests/test_rollback.bats
# Covers: rollback_save_snapshot, rollback_get_latest_snapshot,
#         rollback_list_snapshots, rollback_enforce_retention

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/rollback.sh"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-rb-"*
  rm -rf "$TEST_TMP"
  unset ROLLBACK_RETENTION
}

# ── _rollback_dir ─────────────────────────────────────────────────────────────

@test "_rollback_dir: returns correct path" {
  local result
  result=$(_rollback_dir "my-stack")
  [[ "$result" == *"/stacks/my-stack/.rollback" ]]
}

# ── rollback_save_snapshot ────────────────────────────────────────────────────

@test "rollback_save_snapshot: creates valid JSON snapshot" {
  local stack="test-rb-save-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  # Stub compose command that returns service/image pairs
  local fake_compose="$TEST_TMP/fake-compose"
  cat > "$fake_compose" <<'EOF'
#!/usr/bin/env bash
echo "app ghcr.io/org/app:sha-abc123"
echo "worker ghcr.io/org/worker:sha-def456"
echo "nginx nginx:1.25"
EOF
  chmod +x "$fake_compose"

  run rollback_save_snapshot "$stack" "$fake_compose" "prod"
  [ "$status" -eq 0 ]

  local rollback_dir="$CLI_ROOT/stacks/$stack/.rollback"
  [ -d "$rollback_dir" ]

  local snapshot
  snapshot=$(ls "$rollback_dir"/*.json 2>/dev/null | head -1)
  [ -f "$snapshot" ]

  # Validate JSON
  jq empty "$snapshot"
  [ "$(jq -r '.stack' "$snapshot")" = "$stack" ]
  [ "$(jq -r '.env' "$snapshot")" = "prod" ]
  [ "$(jq -r '.service_count' "$snapshot")" = "3" ]
  [ "$(jq -r '.services.app.image' "$snapshot")" = "ghcr.io/org/app:sha-abc123" ]
  [ "$(jq -r '.services.nginx.image' "$snapshot")" = "nginx:1.25" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "rollback_save_snapshot: handles no running containers" {
  local stack="test-rb-empty-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  # Stub compose that returns nothing
  local fake_compose="$TEST_TMP/fake-compose-empty"
  cat > "$fake_compose" <<'EOF'
#!/usr/bin/env bash
# no output
EOF
  chmod +x "$fake_compose"

  run rollback_save_snapshot "$stack" "$fake_compose" "prod"
  [ "$status" -eq 0 ]

  local snapshot
  snapshot=$(ls "$CLI_ROOT/stacks/$stack/.rollback"/*.json 2>/dev/null | head -1)
  [ -f "$snapshot" ]
  [ "$(jq -r '.service_count' "$snapshot")" = "0" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── rollback_get_latest_snapshot ──────────────────────────────────────────────

@test "rollback_get_latest_snapshot: returns most recent file" {
  local stack="test-rb-latest-$$"
  local rollback_dir="$CLI_ROOT/stacks/$stack/.rollback"
  mkdir -p "$rollback_dir"

  echo '{"timestamp":"2024-01-01"}' > "$rollback_dir/20240101-100000.json"
  sleep 0.1
  echo '{"timestamp":"2024-01-02"}' > "$rollback_dir/20240102-100000.json"
  sleep 0.1
  echo '{"timestamp":"2024-01-03"}' > "$rollback_dir/20240103-100000.json"

  local result
  result=$(rollback_get_latest_snapshot "$stack")
  [[ "$result" == *"20240103-100000.json" ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "rollback_get_latest_snapshot: returns empty when no snapshots" {
  local result
  result=$(rollback_get_latest_snapshot "nonexistent-stack-$$")
  [ -z "$result" ]
}

# ── rollback_list_snapshots ───────────────────────────────────────────────────

@test "rollback_list_snapshots: shows available snapshots" {
  local stack="test-rb-list-$$"
  local rollback_dir="$CLI_ROOT/stacks/$stack/.rollback"
  mkdir -p "$rollback_dir"

  cat > "$rollback_dir/20240101-100000.json" <<'EOF'
{"timestamp":"2024-01-01T10:00:00Z","stack":"test","env":"prod","service_count":3,"services":{}}
EOF

  run rollback_list_snapshots "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"20240101-100000"* ]]
  [[ "$output" == *"3 services"* ]]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "rollback_list_snapshots: warns when no snapshots" {
  run rollback_list_snapshots "nonexistent-stack-$$"
  [[ "$output" == *"No rollback snapshots"* ]]
}

# ── rollback_enforce_retention ────────────────────────────────────────────────

@test "rollback_enforce_retention: keeps only N snapshots" {
  local stack="test-rb-retain-$$"
  local rollback_dir="$CLI_ROOT/stacks/$stack/.rollback"
  mkdir -p "$rollback_dir"

  export ROLLBACK_RETENTION=3

  # Create 6 snapshots
  for i in $(seq 1 6); do
    echo "{}" > "$rollback_dir/2024010${i}-100000.json"
    sleep 0.01
  done

  rollback_enforce_retention "$stack"

  local remaining
  remaining=$(ls "$rollback_dir"/*.json 2>/dev/null | wc -l)
  [ "$remaining" -eq 3 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "rollback_enforce_retention: default retention is 5" {
  local stack="test-rb-default-$$"
  local rollback_dir="$CLI_ROOT/stacks/$stack/.rollback"
  mkdir -p "$rollback_dir"

  unset ROLLBACK_RETENTION

  for i in $(seq 1 8); do
    echo "{}" > "$rollback_dir/2024010${i}-100000.json"
    sleep 0.01
  done

  rollback_enforce_retention "$stack"

  local remaining
  remaining=$(ls "$rollback_dir"/*.json 2>/dev/null | wc -l)
  [ "$remaining" -eq 5 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "rollback_enforce_retention: no-op when under limit" {
  local stack="test-rb-under-$$"
  local rollback_dir="$CLI_ROOT/stacks/$stack/.rollback"
  mkdir -p "$rollback_dir"

  export ROLLBACK_RETENTION=10

  echo "{}" > "$rollback_dir/20240101-100000.json"
  echo "{}" > "$rollback_dir/20240102-100000.json"

  rollback_enforce_retention "$stack"

  local remaining
  remaining=$(ls "$rollback_dir"/*.json 2>/dev/null | wc -l)
  [ "$remaining" -eq 2 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── Property: retention never keeps more than N ───────────────────────────────

@test "Property: retention always keeps exactly min(N, total) snapshots (100 iterations)" {
  for i in $(seq 1 100); do
    local stack="test-rb-prop-$$-$i"
    local rollback_dir="$CLI_ROOT/stacks/$stack/.rollback"
    mkdir -p "$rollback_dir"

    local retention=$(( (RANDOM % 5) + 1 ))
    local total=$(( (RANDOM % 10) + 1 ))
    export ROLLBACK_RETENTION=$retention

    for j in $(seq 1 "$total"); do
      printf -v padded "%02d" "$j"
      echo "{}" > "$rollback_dir/202401${padded}-100000.json"
    done

    rollback_enforce_retention "$stack"

    local remaining
    remaining=$(ls "$rollback_dir"/*.json 2>/dev/null | wc -l)

    local expected=$retention
    [ "$total" -lt "$retention" ] && expected=$total

    [ "$remaining" -eq "$expected" ] || {
      echo "FAILED: retention=$retention total=$total remaining=$remaining expected=$expected"
      rm -rf "$CLI_ROOT/stacks/$stack"
      return 1
    }

    rm -rf "$CLI_ROOT/stacks/$stack"
  done
}

# ── Property: save_snapshot always creates valid JSON ─────────────────────────

@test "Property: save_snapshot always creates valid JSON (50 iterations)" {
  local fake_compose="$TEST_TMP/fake-compose-prop"
  cat > "$fake_compose" <<'EOF'
#!/usr/bin/env bash
echo "app ghcr.io/org/app:latest"
echo "db postgres:16"
EOF
  chmod +x "$fake_compose"

  local envs=("prod" "staging" "dev" "test" "local")

  for i in $(seq 1 50); do
    local stack="test-rb-json-$$-$i"
    mkdir -p "$CLI_ROOT/stacks/$stack"

    local env="${envs[$((RANDOM % ${#envs[@]}))]}"
    export ROLLBACK_RETENTION=2

    rollback_save_snapshot "$stack" "$fake_compose" "$env" >/dev/null 2>&1

    local snapshot
    snapshot=$(ls "$CLI_ROOT/stacks/$stack/.rollback"/*.json 2>/dev/null | head -1)

    [ -f "$snapshot" ] || {
      echo "FAILED iteration $i: no snapshot created"
      rm -rf "$CLI_ROOT/stacks/$stack"
      return 1
    }

    jq empty "$snapshot" || {
      echo "FAILED iteration $i: invalid JSON"
      rm -rf "$CLI_ROOT/stacks/$stack"
      return 1
    }

    [ "$(jq -r '.env' "$snapshot")" = "$env" ] || {
      echo "FAILED iteration $i: env mismatch"
      rm -rf "$CLI_ROOT/stacks/$stack"
      return 1
    }

    rm -rf "$CLI_ROOT/stacks/$stack"
  done
}
