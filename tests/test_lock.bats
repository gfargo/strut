#!/usr/bin/env bats
# ==================================================
# tests/test_lock.bats — Tests for lib/lock.sh (deploy concurrency locks)
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/lock.sh"

  # Sandbox the lock root so tests can't touch ~/.strut/locks.
  export STRUT_LOCK_ROOT="$TEST_TMP/locks"
  mkdir -p "$STRUT_LOCK_ROOT"
}

teardown() {
  common_teardown
  unset STRUT_LOCK_ROOT STRUT_LOCK_STALE_SECONDS
}

# ── Path helpers ──────────────────────────────────────────────────────────────

@test "lock_local_root: honors STRUT_LOCK_ROOT override" {
  [ "$(lock_local_root)" = "$STRUT_LOCK_ROOT" ]
}

@test "lock_local_dir: combines stack+env under root" {
  local dir
  dir=$(lock_local_dir "my-stack" "prod")
  [ "$dir" = "$STRUT_LOCK_ROOT/my-stack-prod.lock.d" ]
}

@test "lock_local_dir: defaults env to 'default' when empty" {
  local dir
  dir=$(lock_local_dir "my-stack" "")
  [ "$dir" = "$STRUT_LOCK_ROOT/my-stack-default.lock.d" ]
}

# ── Acquire / release ─────────────────────────────────────────────────────────

@test "lock_acquire_local: first acquire succeeds and writes info" {
  run lock_acquire_local "s" "prod" "deploy"
  [ "$status" -eq 0 ]
  [ -f "$STRUT_LOCK_ROOT/s-prod.lock.d/info" ]
  grep -q "^pid=$$" "$STRUT_LOCK_ROOT/s-prod.lock.d/info"
  grep -q "^command=deploy" "$STRUT_LOCK_ROOT/s-prod.lock.d/info"
}

@test "lock_acquire_local: second acquire fails with holder info on stderr" {
  lock_acquire_local "s" "prod" "deploy"
  run lock_acquire_local "s" "prod" "deploy"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Deploy lock held"* ]]
  [[ "$output" == *"pid $$"* ]]
}

@test "lock_release_local: removes the lock directory" {
  lock_acquire_local "s" "prod" "deploy"
  [ -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
  lock_release_local "s" "prod"
  [ ! -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
}

@test "lock_release_local: idempotent when lock not held" {
  run lock_release_local "s" "prod"
  [ "$status" -eq 0 ]
}

@test "lock_acquire_local: can reacquire after release" {
  lock_acquire_local "s" "prod" "deploy"
  lock_release_local "s" "prod"
  run lock_acquire_local "s" "prod" "deploy"
  [ "$status" -eq 0 ]
}

@test "lock_acquire_local: echoes a nonce on stdout, recorded in the info file" {
  run lock_acquire_local "s" "prod" "deploy"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -q "^nonce=$output\$" "$STRUT_LOCK_ROOT/s-prod.lock.d/info"
}

# strut#383 (bonus fix): a lock force-broken and re-acquired by a different
# process must not be deleted by the FIRST process's own (now-stale) EXIT
# cleanup once it eventually finishes.
@test "lock_release_local: nonce mismatch leaves a lock re-acquired by someone else alone" {
  local first_nonce
  first_nonce=$(lock_acquire_local "s" "prod" "deploy")
  lock_force_break_local "s" "prod"
  lock_acquire_local "s" "prod" "deploy" >/dev/null   # a second process re-acquires

  run lock_release_local "s" "prod" "$first_nonce"
  [ "$status" -eq 0 ]
  [ -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
}

@test "lock_release_local: matching nonce releases normally" {
  local nonce
  nonce=$(lock_acquire_local "s" "prod" "deploy")
  run lock_release_local "s" "prod" "$nonce"
  [ "$status" -eq 0 ]
  [ ! -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
}

@test "lock_release_local: no nonce given releases unconditionally (backward compat)" {
  lock_acquire_local "s" "prod" "deploy" >/dev/null
  run lock_release_local "s" "prod"
  [ "$status" -eq 0 ]
  [ ! -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
}

@test "lock_acquire_local: different env doesn't conflict" {
  lock_acquire_local "s" "prod" "deploy"
  run lock_acquire_local "s" "staging" "deploy"
  [ "$status" -eq 0 ]
}

@test "lock_acquire_local: different stack doesn't conflict" {
  lock_acquire_local "stack-a" "prod" "deploy"
  run lock_acquire_local "stack-b" "prod" "deploy"
  [ "$status" -eq 0 ]
}

# ── Read info ────────────────────────────────────────────────────────────────

@test "lock_read_info: returns value for existing key" {
  lock_acquire_local "s" "prod" "rollback"
  result=$(lock_read_info "$STRUT_LOCK_ROOT/s-prod.lock.d/info" "command")
  [ "$result" = "rollback" ]
}

@test "lock_read_info: missing file returns non-zero" {
  run lock_read_info "/nonexistent/path" "pid"
  [ "$status" -ne 0 ]
}

@test "lock_read_info: missing key yields empty string" {
  lock_acquire_local "s" "prod" "deploy"
  result=$(lock_read_info "$STRUT_LOCK_ROOT/s-prod.lock.d/info" "does_not_exist")
  [ -z "$result" ]
}

# ── Stale detection ───────────────────────────────────────────────────────────

@test "lock_is_stale_local: returns 2 (no lock) when not held" {
  run lock_is_stale_local "s" "prod"
  [ "$status" -eq 2 ]
}

@test "lock_is_stale_local: returns 1 (not stale) for live current process" {
  lock_acquire_local "s" "prod" "deploy"
  run lock_is_stale_local "s" "prod"
  [ "$status" -eq 1 ]
}

@test "lock_is_stale_local: returns 0 (stale) when age exceeds threshold" {
  lock_acquire_local "s" "prod" "deploy"
  # Rewrite started to 1 hour ago (same host) with a dead pid
  local past
  past=$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d "1 hour ago" +%FT%TZ)
  cat > "$STRUT_LOCK_ROOT/s-prod.lock.d/info" <<EOF
pid=999999
host=$(hostname)
started=$past
command=deploy
EOF
  export STRUT_LOCK_STALE_SECONDS=60
  run lock_is_stale_local "s" "prod"
  [ "$status" -eq 0 ]
}

@test "lock_is_stale_local: returns 0 (stale) when pid is dead on same host" {
  lock_acquire_local "s" "prod" "deploy"
  # Replace pid with one that definitely doesn't exist
  sed -i.bak "s/^pid=.*/pid=999999/" "$STRUT_LOCK_ROOT/s-prod.lock.d/info"
  rm -f "$STRUT_LOCK_ROOT/s-prod.lock.d/info.bak"
  run lock_is_stale_local "s" "prod"
  [ "$status" -eq 0 ]
}

# strut#383: a lock is declared stale purely by age even though its holder
# pid is alive — a live long-running deploy (image pull, --no-cache
# rebuild, blue-green health poll) routinely exceeds the default 600s
# threshold, so the age fallback must never override a verifiable live pid.
@test "lock_is_stale_local: NOT stale when pid is alive, even past the age threshold" {
  lock_acquire_local "s" "prod" "deploy"
  # Rewrite started to 1 hour ago, same host, but keep OUR OWN pid ($$) —
  # guaranteed alive for the duration of this test.
  local past
  past=$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d "1 hour ago" +%FT%TZ)
  cat > "$STRUT_LOCK_ROOT/s-prod.lock.d/info" <<EOF
pid=$$
host=$(hostname)
started=$past
command=deploy
EOF
  export STRUT_LOCK_STALE_SECONDS=60
  run lock_is_stale_local "s" "prod"
  [ "$status" -eq 1 ]
}

@test "lock_is_stale_local: age fallback still applies for a cross-host lock (pid unverifiable)" {
  lock_acquire_local "s" "prod" "deploy"
  local past
  past=$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d "1 hour ago" +%FT%TZ)
  cat > "$STRUT_LOCK_ROOT/s-prod.lock.d/info" <<EOF
pid=$$
host=some-other-host
started=$past
command=deploy
EOF
  export STRUT_LOCK_STALE_SECONDS=60
  run lock_is_stale_local "s" "prod"
  [ "$status" -eq 0 ]
}

# ── Force break ───────────────────────────────────────────────────────────────

@test "lock_force_break_local: clears lock even if held" {
  lock_acquire_local "s" "prod" "deploy"
  # Pretend another process owns it — force break should still work
  echo "pid=999999" > "$STRUT_LOCK_ROOT/s-prod.lock.d/info"
  lock_force_break_local "s" "prod"
  [ ! -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
}

@test "lock_force_break_local: idempotent when nothing held" {
  run lock_force_break_local "s" "prod"
  [ "$status" -eq 0 ]
}

# ── Status rendering ──────────────────────────────────────────────────────────

@test "lock_status_local: exits 1 when not held" {
  run lock_status_local "s" "prod"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not held"* ]]
}

@test "lock_status_local: prints pid/host/command when held" {
  lock_acquire_local "s" "prod" "deploy"
  run lock_status_local "s" "prod"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pid:"*"$$"* ]]
  [[ "$output" == *"command: deploy"* ]]
  [[ "$output" == *"status:  active"* ]]
}

@test "lock_status_local: flags stale locks" {
  lock_acquire_local "s" "prod" "deploy"
  sed -i.bak "s/^pid=.*/pid=999999/" "$STRUT_LOCK_ROOT/s-prod.lock.d/info"
  rm -f "$STRUT_LOCK_ROOT/s-prod.lock.d/info.bak"
  run lock_status_local "s" "prod"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
}

# ── lock_acquire / lock_release (unified) ─────────────────────────────────────

@test "lock_acquire: without VPS_HOST skips remote, acquires local only" {
  unset VPS_HOST
  run lock_acquire "s" "prod" "deploy"
  [ "$status" -eq 0 ]
  [ -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
}

@test "lock_release: without VPS_HOST releases local, no-op remote" {
  unset VPS_HOST
  lock_acquire "s" "prod" "deploy"
  lock_release "s" "prod"
  [ ! -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
}

# ── Remote path expression ───────────────────────────────────────────────────

@test "_lock_remote_dir_expr: uses VPS_DEPLOY_DIR and .strut-locks subdir" {
  result=$(_lock_remote_dir_expr "my-stack" "prod")
  [[ "$result" == *".strut-locks"*"/my-stack-prod.lock.d" ]]
  [[ "$result" == *"VPS_DEPLOY_DIR"* ]]
}

# ── Remote lock SSH opts (OSS-465: VPS_PORT/VPS_SSH_KEY, not SSH_PORT/SSH_KEY) ─

@test "lock_acquire_remote: builds ssh opts from VPS_PORT/VPS_SSH_KEY" {
  export VPS_HOST="example.com"
  export VPS_PORT="2222"
  export VPS_SSH_KEY="$TEST_TMP/testkey"
  touch "$VPS_SSH_KEY"
  export SSH_PORT="9999"
  export SSH_KEY="$TEST_TMP/wrongkey"

  ssh() { echo "$@" > "$TEST_TMP/ssh_call"; }
  export -f ssh

  run lock_acquire_remote "s" "prod" "deploy"
  [[ "$(cat "$TEST_TMP/ssh_call")" == *"-p 2222"* ]]
  [[ "$(cat "$TEST_TMP/ssh_call")" == *"-i $TEST_TMP/testkey"* ]]
  [[ "$(cat "$TEST_TMP/ssh_call")" != *"9999"* ]]
  [[ "$(cat "$TEST_TMP/ssh_call")" != *"wrongkey"* ]]
}

@test "lock_release_remote: builds ssh opts from VPS_PORT/VPS_SSH_KEY" {
  export VPS_HOST="example.com"
  export VPS_PORT="2222"
  export VPS_SSH_KEY="$TEST_TMP/testkey"
  touch "$VPS_SSH_KEY"
  export SSH_PORT="9999"
  export SSH_KEY="$TEST_TMP/wrongkey"

  ssh() { echo "$@" > "$TEST_TMP/ssh_call"; }
  export -f ssh

  run lock_release_remote "s" "prod"
  [[ "$(cat "$TEST_TMP/ssh_call")" == *"-p 2222"* ]]
  [[ "$(cat "$TEST_TMP/ssh_call")" == *"-i $TEST_TMP/testkey"* ]]
}

@test "lock_status_remote: builds ssh opts from VPS_PORT/VPS_SSH_KEY" {
  export VPS_HOST="example.com"
  export VPS_PORT="2222"
  export VPS_SSH_KEY="$TEST_TMP/testkey"
  touch "$VPS_SSH_KEY"
  export SSH_PORT="9999"
  export SSH_KEY="$TEST_TMP/wrongkey"

  ssh() { echo "$@" > "$TEST_TMP/ssh_call"; }
  export -f ssh

  run lock_status_remote "s" "prod"
  [[ "$(cat "$TEST_TMP/ssh_call")" == *"-p 2222"* ]]
  [[ "$(cat "$TEST_TMP/ssh_call")" == *"-i $TEST_TMP/testkey"* ]]
}

# ── Property: many acquire/release cycles never leak ────────────────────────

@test "Property: 50 acquire/release cycles leave clean state" {
  for i in $(seq 1 50); do
    lock_acquire_local "s" "prod" "deploy" >/dev/null 2>&1
    lock_release_local "s" "prod"
  done
  [ ! -d "$STRUT_LOCK_ROOT/s-prod.lock.d" ]
}

@test "Property: concurrent acquire races — only one wins" {
  # Simulate 10 parallel acquire attempts; count successes.
  local wins=0
  local tmp="$TEST_TMP/races"
  mkdir -p "$tmp"
  for i in $(seq 1 10); do
    (
      if lock_acquire_local "race-stack" "prod" "deploy" 2>/dev/null; then
        echo "win" > "$tmp/$i"
      fi
    ) &
  done
  wait
  wins=$(find "$tmp" -type f -name "[0-9]*" | wc -l | tr -d ' ')
  # Exactly one winner
  [ "$wins" -eq 1 ]
  # Clean up
  lock_release_local "race-stack" "prod"
}
