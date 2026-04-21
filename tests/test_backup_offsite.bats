#!/usr/bin/env bats
# ==================================================
# tests/test_backup_offsite.bats — Offsite sync (S3 / R2 / B2)
# ==================================================
# Exercises config parsing, provider dispatch, and the sync/list/restore
# flows. CLI calls are captured via a stub aws/b2 on PATH — we assert the
# command shape rather than hitting any real backend.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/backup.sh"

  # Sandbox BACKUP_LOCAL_DIR so _backup_dir returns a known path.
  export BACKUP_LOCAL_DIR="$TEST_TMP/backups"
  mkdir -p "$BACKUP_LOCAL_DIR"

  # CLI-stub directory — tests insert into PATH as needed.
  export STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  export CALL_LOG="$TEST_TMP/calls.log"
  : > "$CALL_LOG"
}

teardown() {
  rm -rf "$TEST_TMP"
  unset BACKUP_LOCAL_DIR STUB_BIN CALL_LOG DRY_RUN
  unset BACKUP_OFFSITE BACKUP_OFFSITE_BUCKET BACKUP_OFFSITE_PREFIX R2_ACCOUNT_ID
}

_install_aws_stub() {
  cat > "$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$CALL_LOG"
# Simulate success unless the magic env var says to fail.
[ "${STUB_AWS_FAIL:-0}" = "1" ] && exit 1
# For `ls`, emit a fake listing.
for arg in "$@"; do
  if [ "$arg" = "ls" ]; then
    echo "2026-04-20 10:00:00       1024 postgres-20260420-100000.sql"
    echo "2026-04-19 10:00:00       2048 postgres-20260419-100000.sql"
  fi
done
exit 0
EOF
  chmod +x "$STUB_BIN/aws"
  export PATH="$STUB_BIN:$PATH"
}

_install_b2_stub() {
  cat > "$STUB_BIN/b2" <<'EOF'
#!/usr/bin/env bash
echo "b2 $*" >> "$CALL_LOG"
[ "${STUB_B2_FAIL:-0}" = "1" ] && exit 1
for arg in "$@"; do
  if [ "$arg" = "ls" ]; then
    echo "postgres-20260420-100000.sql 1024"
  fi
done
exit 0
EOF
  chmod +x "$STUB_BIN/b2"
  export PATH="$STUB_BIN:$PATH"
}

# ── offsite_provider / offsite_enabled ───────────────────────────────────────

@test "offsite_provider: lowercases and returns configured provider" {
  BACKUP_OFFSITE=S3 run offsite_provider
  [ "$output" = "s3" ]

  BACKUP_OFFSITE=r2 run offsite_provider
  [ "$output" = "r2" ]
}

@test "offsite_enabled: none → disabled" {
  BACKUP_OFFSITE=none run offsite_enabled
  [ "$status" -ne 0 ]
}

@test "offsite_enabled: unset → disabled" {
  unset BACKUP_OFFSITE
  run offsite_enabled
  [ "$status" -ne 0 ]
}

@test "offsite_enabled: s3 without aws CLI → disabled with warning" {
  # Clear PATH so aws is unavailable.
  PATH="/usr/bin" BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=x \
    run offsite_enabled
  [ "$status" -ne 0 ]
  [[ "$output" == *"aws"* ]]
}

@test "offsite_enabled: s3 without bucket → disabled" {
  _install_aws_stub
  BACKUP_OFFSITE=s3 run offsite_enabled
  [ "$status" -ne 0 ]
  [[ "$output" == *"BACKUP_OFFSITE_BUCKET"* ]]
}

@test "offsite_enabled: s3 + bucket + aws installed → enabled" {
  _install_aws_stub
  BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=my-bucket run offsite_enabled
  [ "$status" -eq 0 ]
}

@test "offsite_enabled: unknown provider → disabled" {
  BACKUP_OFFSITE=gopher BACKUP_OFFSITE_BUCKET=x run offsite_enabled
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown"* ]]
}

# ── URL construction ─────────────────────────────────────────────────────────

@test "_offsite_remote_url: s3 uses s3:// scheme + prefix" {
  BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=bk BACKUP_OFFSITE_PREFIX=pfx \
    run _offsite_remote_url "mystack" "pg-1.sql"
  [ "$output" = "s3://bk/pfx/pg-1.sql" ]
}

@test "_offsite_remote_url: r2 also uses s3:// scheme" {
  BACKUP_OFFSITE=r2 BACKUP_OFFSITE_BUCKET=bk BACKUP_OFFSITE_PREFIX=pfx \
    run _offsite_remote_url "mystack" "pg-1.sql"
  [ "$output" = "s3://bk/pfx/pg-1.sql" ]
}

@test "_offsite_remote_url: b2 uses b2:// scheme" {
  BACKUP_OFFSITE=b2 BACKUP_OFFSITE_BUCKET=bk BACKUP_OFFSITE_PREFIX=pfx \
    run _offsite_remote_url "mystack" "pg-1.sql"
  [ "$output" = "b2://bk/pfx/pg-1.sql" ]
}

@test "_offsite_remote_url: prefix defaults to stack name" {
  BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=bk \
    run _offsite_remote_url "mystack" "pg-1.sql"
  [ "$output" = "s3://bk/mystack/pg-1.sql" ]
}

@test "_offsite_aws_opts: r2 with R2_ACCOUNT_ID → endpoint-url" {
  BACKUP_OFFSITE=r2 R2_ACCOUNT_ID=abc123 run _offsite_aws_opts
  [[ "$output" == *"endpoint-url"* ]]
  [[ "$output" == *"abc123.r2.cloudflarestorage.com"* ]]
}

@test "_offsite_aws_opts: s3 returns empty" {
  BACKUP_OFFSITE=s3 run _offsite_aws_opts
  [ -z "$output" ]
}

# ── offsite_sync_file ────────────────────────────────────────────────────────

@test "offsite_sync_file: s3 issues aws s3 cp" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk BACKUP_OFFSITE_PREFIX=s
  echo "fake" > "$BACKUP_LOCAL_DIR/postgres-1.sql"

  run offsite_sync_file "mystack" "$BACKUP_LOCAL_DIR/postgres-1.sql"
  [ "$status" -eq 0 ]

  local log
  log=$(cat "$CALL_LOG")
  [[ "$log" == *"aws"* ]]
  [[ "$log" == *"s3 cp"* ]]
  [[ "$log" == *"$BACKUP_LOCAL_DIR/postgres-1.sql"* ]]
  [[ "$log" == *"s3://mybk/s/postgres-1.sql"* ]]
}

@test "offsite_sync_file: r2 injects endpoint-url" {
  _install_aws_stub
  export BACKUP_OFFSITE=r2 BACKUP_OFFSITE_BUCKET=mybk R2_ACCOUNT_ID=acct
  echo "fake" > "$BACKUP_LOCAL_DIR/postgres-1.sql"

  run offsite_sync_file "mystack" "$BACKUP_LOCAL_DIR/postgres-1.sql"
  [ "$status" -eq 0 ]

  local log
  log=$(cat "$CALL_LOG")
  [[ "$log" == *"endpoint-url"* ]]
  [[ "$log" == *"acct.r2.cloudflarestorage.com"* ]]
}

@test "offsite_sync_file: b2 issues b2 upload-file" {
  _install_b2_stub
  export BACKUP_OFFSITE=b2 BACKUP_OFFSITE_BUCKET=mybk BACKUP_OFFSITE_PREFIX=s
  echo "fake" > "$BACKUP_LOCAL_DIR/postgres-1.sql"

  run offsite_sync_file "mystack" "$BACKUP_LOCAL_DIR/postgres-1.sql"
  [ "$status" -eq 0 ]

  local log
  log=$(cat "$CALL_LOG")
  [[ "$log" == *"b2 upload-file mybk"* ]]
  [[ "$log" == *"s/postgres-1.sql"* ]]
}

@test "offsite_sync_file: DRY_RUN prints and skips CLI" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk
  export DRY_RUN=true
  echo "fake" > "$BACKUP_LOCAL_DIR/postgres-1.sql"

  run offsite_sync_file "mystack" "$BACKUP_LOCAL_DIR/postgres-1.sql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"s3://mybk/mystack/postgres-1.sql"* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "offsite_sync_file: missing local file → fail non-fatal" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk
  run offsite_sync_file "mystack" "$BACKUP_LOCAL_DIR/does-not-exist.sql"
  [ "$status" -ne 0 ]
}

@test "offsite_sync_file: aws failure warns but returns 1" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk STUB_AWS_FAIL=1
  echo "fake" > "$BACKUP_LOCAL_DIR/postgres-1.sql"

  run offsite_sync_file "mystack" "$BACKUP_LOCAL_DIR/postgres-1.sql"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed"* ]]
}

# ── offsite_sync_latest ──────────────────────────────────────────────────────

@test "offsite_sync_latest: picks newest matching file" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk

  echo "old" > "$BACKUP_LOCAL_DIR/postgres-20260418-100000.sql"
  sleep 1
  echo "new" > "$BACKUP_LOCAL_DIR/postgres-20260420-100000.sql"
  echo "other" > "$BACKUP_LOCAL_DIR/neo4j-1.dump"

  run offsite_sync_latest "mystack" "postgres-*.sql"
  [ "$status" -eq 0 ]

  local log
  log=$(cat "$CALL_LOG")
  [[ "$log" == *"postgres-20260420-100000.sql"* ]]
  [[ "$log" != *"postgres-20260418-100000.sql"* ]]
  [[ "$log" != *"neo4j"* ]]
}

@test "offsite_sync_latest: no-op when offsite disabled" {
  unset BACKUP_OFFSITE
  echo "x" > "$BACKUP_LOCAL_DIR/postgres-1.sql"
  run offsite_sync_latest "mystack" "postgres-*.sql"
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "offsite_sync_latest: no-op when no matching file" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk
  run offsite_sync_latest "mystack" "postgres-*.sql"
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

# ── offsite_sync_all ─────────────────────────────────────────────────────────

@test "offsite_sync_all: syncs every backup file, skips metadata" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk

  echo "a" > "$BACKUP_LOCAL_DIR/postgres-1.sql"
  echo "b" > "$BACKUP_LOCAL_DIR/neo4j-1.dump"
  echo '{}' > "$BACKUP_LOCAL_DIR/postgres-1.sql.meta"
  echo '{}' > "$BACKUP_LOCAL_DIR/ignored.json"

  run offsite_sync_all "mystack"
  [ "$status" -eq 0 ]

  local log
  log=$(cat "$CALL_LOG")
  [[ "$log" == *"postgres-1.sql"* ]]
  [[ "$log" == *"neo4j-1.dump"* ]]
  # .meta / .json should be skipped
  [[ "$log" != *"postgres-1.sql.meta"* ]]
  [[ "$log" != *"ignored.json"* ]]
}

@test "offsite_sync_all: disabled provider → returns 1 with warning" {
  unset BACKUP_OFFSITE
  run offsite_sync_all "mystack"
  [ "$status" -ne 0 ]
}

# ── offsite_list ─────────────────────────────────────────────────────────────

@test "offsite_list: s3 emits aws s3 ls with prefix" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk BACKUP_OFFSITE_PREFIX=pfx
  run offsite_list "mystack"
  [ "$status" -eq 0 ]

  local log
  log=$(cat "$CALL_LOG")
  [[ "$log" == *"s3 ls"* ]]
  [[ "$log" == *"s3://mybk/pfx/"* ]]

  # Listing output from stub is passed through.
  [[ "$output" == *"postgres-20260420-100000.sql"* ]]
}

# ── offsite_restore ──────────────────────────────────────────────────────────

@test "offsite_restore: s3 downloads into backup dir" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk
  run offsite_restore "mystack" "postgres-1.sql"
  [ "$status" -eq 0 ]

  local log
  log=$(cat "$CALL_LOG")
  [[ "$log" == *"s3 cp"* ]]
  [[ "$log" == *"s3://mybk/mystack/postgres-1.sql"* ]]
  [[ "$log" == *"$BACKUP_LOCAL_DIR/postgres-1.sql"* ]]
}

@test "offsite_restore: DRY_RUN prints and skips CLI" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk DRY_RUN=true
  run offsite_restore "mystack" "postgres-1.sql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "offsite_restore: missing filename arg fails" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk
  run offsite_restore "mystack" ""
  [ "$status" -ne 0 ]
}

# ── offsite_status ───────────────────────────────────────────────────────────

@test "offsite_status: prints provider and bucket" {
  _install_aws_stub
  export BACKUP_OFFSITE=s3 BACKUP_OFFSITE_BUCKET=mybk BACKUP_OFFSITE_PREFIX=pfx
  run offsite_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"s3"* ]]
  [[ "$output" == *"mybk"* ]]
  [[ "$output" == *"pfx"* ]]
  [[ "$output" == *"ENABLED"* ]]
}

@test "offsite_status: reports DISABLED when unconfigured" {
  unset BACKUP_OFFSITE
  run offsite_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISABLED"* ]]
}
