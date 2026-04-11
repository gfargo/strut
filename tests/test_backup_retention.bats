#!/usr/bin/env bats
# ==================================================
# tests/test_backup_retention.bats — Tests for backup retention policy
# ==================================================
# Run:  bats tests/test_backup_retention.bats
# Covers: enforce_retention_policy, delete_backup, create_backup_metadata

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  confirm() { return 0; }

  source "$CLI_ROOT/lib/backup.sh"
}

teardown() {
  # Clean up any test stacks
  rm -rf "$CLI_ROOT/stacks/test-ret-"*
  rm -rf "$TEST_TMP"
  unset BACKUP_LOCAL_DIR
}

# ── delete_backup ─────────────────────────────────────────────────────────────

@test "delete_backup: removes file and logs to retention.log" {
  local stack="test-ret-del-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"
  echo "data" > "$backup_dir/postgres-20240101-120000.sql"

  run delete_backup "$backup_dir/postgres-20240101-120000.sql" "test deletion"
  [ "$status" -eq 0 ]
  [ ! -f "$backup_dir/postgres-20240101-120000.sql" ]
  [ -f "$backup_dir/retention.log" ]
  grep -q "test deletion" "$backup_dir/retention.log"

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "delete_backup: fails for missing file" {
  run delete_backup "$TEST_TMP/nonexistent.sql" "test"
  [ "$status" -eq 1 ]
}

@test "delete_backup: removes associated metadata file" {
  local stack="test-ret-meta-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  local metadata_dir="$backup_dir/metadata"
  mkdir -p "$metadata_dir"
  echo "data" > "$backup_dir/postgres-20240101-120000.sql"
  echo '{}' > "$metadata_dir/postgres-20240101-120000.json"

  delete_backup "$backup_dir/postgres-20240101-120000.sql" "cleanup"
  [ ! -f "$metadata_dir/postgres-20240101-120000.json" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── create_backup_metadata ────────────────────────────────────────────────────

@test "create_backup_metadata: creates valid JSON metadata file" {
  local stack="test-ret-cmeta-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"
  echo "data" > "$backup_dir/postgres-20240101-120000.sql"

  run create_backup_metadata "$stack" "$backup_dir/postgres-20240101-120000.sql" "postgres" ""
  [ "$status" -eq 0 ]

  local metadata_file="$CLI_ROOT/stacks/$stack/backups/metadata/postgres-20240101-120000.json"
  [ -f "$metadata_file" ]
  # Validate JSON
  jq empty "$metadata_file"
  # Check fields
  [ "$(jq -r '.service' "$metadata_file")" = "postgres" ]
  [ "$(jq -r '.stack' "$metadata_file")" = "$stack" ]
  [ "$(jq -r '.backup_id' "$metadata_file")" = "postgres-20240101-120000" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "create_backup_metadata: fails for missing backup file" {
  run create_backup_metadata "test-stack" "$TEST_TMP/nonexistent.sql" "postgres" ""
  [ "$status" -eq 1 ]
}

@test "create_backup_metadata: includes verification result when provided" {
  local stack="test-ret-verify-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"
  echo "data" > "$backup_dir/postgres-20240201-120000.sql"

  run create_backup_metadata "$stack" "$backup_dir/postgres-20240201-120000.sql" "postgres" '{"tables_verified":5}'
  [ "$status" -eq 0 ]

  local metadata_file="$CLI_ROOT/stacks/$stack/backups/metadata/postgres-20240201-120000.json"
  [ "$(jq -r '.verification.status' "$metadata_file")" = "passed" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── enforce_retention_policy ──────────────────────────────────────────────────

@test "enforce_retention_policy: keeps backups within retention count" {
  local stack="test-ret-keep-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  # Create backup.conf with retain_count=3, retain_days=1
  cat > "$CLI_ROOT/stacks/$stack/backup.conf" <<'EOF'
BACKUP_RETAIN_DAYS=1
BACKUP_RETAIN_COUNT=3
EOF

  # Create 5 backups, all "old" (2 days ago)
  for i in $(seq 1 5); do
    local f="$backup_dir/postgres-2024010${i}-120000.sql"
    echo "data$i" > "$f"
    touch -t "$(date -v-2d +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$f"
    sleep 0.1
  done

  run enforce_retention_policy "$stack" "postgres"
  [ "$status" -eq 0 ]

  # Should keep the 3 newest (retain_count), delete the 2 oldest
  local remaining
  remaining=$(ls "$backup_dir"/postgres-*.sql 2>/dev/null | wc -l)
  [ "$remaining" -eq 3 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "enforce_retention_policy: does not delete recent backups" {
  local stack="test-ret-recent-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  cat > "$CLI_ROOT/stacks/$stack/backup.conf" <<'EOF'
BACKUP_RETAIN_DAYS=30
BACKUP_RETAIN_COUNT=2
EOF

  # Create 5 recent backups (today)
  for i in $(seq 1 5); do
    echo "data$i" > "$backup_dir/postgres-2024010${i}-120000.sql"
    sleep 0.1
  done

  run enforce_retention_policy "$stack" "postgres"
  [ "$status" -eq 0 ]

  # All 5 should remain — they're within retain_days even though count > retain_count
  local remaining
  remaining=$(ls "$backup_dir"/postgres-*.sql 2>/dev/null | wc -l)
  [ "$remaining" -eq 5 ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

@test "enforce_retention_policy: uses defaults when no backup.conf" {
  local stack="test-ret-defaults-$$"
  local backup_dir="$CLI_ROOT/stacks/$stack/backups"
  mkdir -p "$backup_dir"

  # Create a recent backup — should survive default 30-day retention
  echo "data" > "$backup_dir/postgres-20240101-120000.sql"

  run enforce_retention_policy "$stack" "postgres"
  [ "$status" -eq 0 ]
  [ -f "$backup_dir/postgres-20240101-120000.sql" ]

  rm -rf "$CLI_ROOT/stacks/$stack"
}

# ── Property: Retention never deletes below retain_count ──────────────────────

@test "Property: Retention never deletes below retain_count (50 iterations)" {
  for i in $(seq 1 50); do
    local stack="test-ret-prop-$$-$i"
    local backup_dir="$CLI_ROOT/stacks/$stack/backups"
    mkdir -p "$backup_dir"

    # Random retain_count between 1 and 5
    local retain_count=$(( (RANDOM % 5) + 1 ))
    # Random number of backups between 1 and 10
    local num_backups=$(( (RANDOM % 10) + 1 ))

    cat > "$CLI_ROOT/stacks/$stack/backup.conf" <<EOF
BACKUP_RETAIN_DAYS=0
BACKUP_RETAIN_COUNT=$retain_count
EOF

    # Create backups with staggered timestamps
    for j in $(seq 1 "$num_backups"); do
      local f="$backup_dir/postgres-20240${j}01-120000.sql"
      echo "data" > "$f"
      # Make them all "old" so retention would want to delete them
      touch -t "$(date -v-60d +%Y%m%d%H%M.%S 2>/dev/null || date -d '60 days ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$f"
      sleep 0.01
    done

    enforce_retention_policy "$stack" "postgres" >/dev/null 2>&1

    local remaining
    remaining=$(ls "$backup_dir"/postgres-*.sql 2>/dev/null | wc -l)

    # Property: remaining >= min(retain_count, num_backups)
    local expected_min=$retain_count
    [ "$num_backups" -lt "$retain_count" ] && expected_min=$num_backups
    [ "$remaining" -ge "$expected_min" ] || {
      echo "FAILED: retain_count=$retain_count num_backups=$num_backups remaining=$remaining expected_min=$expected_min"
      rm -rf "$CLI_ROOT/stacks/$stack"
      return 1
    }

    rm -rf "$CLI_ROOT/stacks/$stack"
  done
}
