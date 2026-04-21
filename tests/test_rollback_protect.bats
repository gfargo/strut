#!/usr/bin/env bats
# ==================================================
# tests/test_rollback_protect.bats — rollback-aware docker image pruning
# ==================================================
# Covers:
#   rollback_protected_images  (lib/rollback.sh) — image extraction + dedup
#   docker_prune_protected     (lib/docker.sh)   — manual rmi respecting
#                                                  protect set + DRY_RUN
#
# We do not run Docker; docker_prune_protected is exercised with DRY_RUN=true
# so it prints what it would remove.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/rollback.sh"
  source "$CLI_ROOT/lib/docker.sh"

  # Each test gets its own stack + rollback dir, sandboxed under TEST_TMP via
  # CLI_ROOT-rooted paths. We override _rollback_dir by overriding CLI_ROOT.
  export SANDBOX_ROOT="$TEST_TMP/sandbox"
  mkdir -p "$SANDBOX_ROOT/stacks"
}

teardown() {
  common_teardown
  unset SANDBOX_ROOT ROLLBACK_RETENTION_DAYS PRUNE_PROTECT_ROLLBACK_IMAGES DRY_RUN
}

# Helper — write a snapshot with given iso-timestamp and image list.
# Args: <stack> <timestamp> <image1> [image2...]
_write_snapshot() {
  local stack="$1" ts="$2"; shift 2
  local dir="$SANDBOX_ROOT/stacks/$stack/.rollback"
  mkdir -p "$dir"
  local ts_file
  ts_file=$(echo "$ts" | tr -d ':-')
  ts_file="${ts_file%Z}"
  local file="$dir/${ts_file}.json"

  local services="{" first=true
  local n=0
  local img
  for img in "$@"; do
    if $first; then first=false; else services+=","; fi
    services+="\"svc$n\":{\"image\":\"$img\"}"
    n=$((n + 1))
  done
  services+="}"

  cat > "$file" <<EOF
{
  "timestamp": "$ts",
  "stack": "$stack",
  "env": "test",
  "service_count": $n,
  "services": $services
}
EOF
  echo "$file"
}

# Override _rollback_dir to point into the sandbox.
_sandbox_dir_override() {
  eval '
_rollback_dir() {
  echo "$SANDBOX_ROOT/stacks/$1/.rollback"
}'
}

# ── rollback_protected_images ────────────────────────────────────────────────

@test "rollback_protected_images: empty dir → no output" {
  _sandbox_dir_override
  local out
  out=$(rollback_protected_images "nope" 30)
  [ -z "$out" ]
}

@test "rollback_protected_images: recent snapshot → images listed" {
  _sandbox_dir_override
  local stack="pp-recent"
  local now_iso
  now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _write_snapshot "$stack" "$now_iso" \
    "ghcr.io/org/api:sha-111" \
    "nginx:1.25" >/dev/null

  run rollback_protected_images "$stack" 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/org/api:sha-111"* ]]
  [[ "$output" == *"nginx:1.25"* ]]
}

@test "rollback_protected_images: old snapshot excluded by retention window" {
  _sandbox_dir_override
  local stack="pp-old"
  # 100 days ago — well outside 30-day window
  _write_snapshot "$stack" "2020-01-01T00:00:00Z" \
    "ghcr.io/org/api:ancient" >/dev/null

  run rollback_protected_images "$stack" 30
  [ "$status" -eq 0 ]
  [[ "$output" != *"ghcr.io/org/api:ancient"* ]]
}

@test "rollback_protected_images: retention 0 protects every snapshot" {
  _sandbox_dir_override
  local stack="pp-all"
  _write_snapshot "$stack" "2020-01-01T00:00:00Z" \
    "ghcr.io/org/api:ancient" >/dev/null

  run rollback_protected_images "$stack" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/org/api:ancient"* ]]
}

@test "rollback_protected_images: duplicates are deduped across snapshots" {
  _sandbox_dir_override
  local stack="pp-dedup"
  local now_iso
  now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _write_snapshot "$stack" "$now_iso" \
    "ghcr.io/org/api:sha-1" "nginx:1.25" >/dev/null
  _write_snapshot "$stack" "${now_iso%Z}.001Z" \
    "ghcr.io/org/api:sha-1" "redis:7" >/dev/null 2>/dev/null || \
    _write_snapshot "$stack" "$(date -u -v+1S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '+1 sec' +"%Y-%m-%dT%H:%M:%SZ")" \
      "ghcr.io/org/api:sha-1" "redis:7" >/dev/null

  run rollback_protected_images "$stack" 30
  [ "$status" -eq 0 ]

  # api:sha-1 should appear exactly once
  local api_count
  api_count=$(echo "$output" | grep -c 'ghcr.io/org/api:sha-1' || true)
  [ "$api_count" -eq 1 ]
}

@test "rollback_protected_images: env override ROLLBACK_RETENTION_DAYS" {
  _sandbox_dir_override
  local stack="pp-envret"
  # 5-day-old snapshot
  local five_days_ago
  five_days_ago=$(date -u -v-5d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d '-5 days' +"%Y-%m-%dT%H:%M:%SZ")
  _write_snapshot "$stack" "$five_days_ago" "ghcr.io/org/mid:v1" >/dev/null

  # With 2-day window → excluded
  ROLLBACK_RETENTION_DAYS=2
  export ROLLBACK_RETENTION_DAYS
  run rollback_protected_images "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ghcr.io/org/mid:v1"* ]]

  # With 10-day window → included
  ROLLBACK_RETENTION_DAYS=10
  export ROLLBACK_RETENTION_DAYS
  run rollback_protected_images "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/org/mid:v1"* ]]
}

# ── docker_prune_protected ───────────────────────────────────────────────────
#
# We stub `docker` on PATH so the function's internals (docker ps, docker images,
# docker rmi) run through our fake. In DRY_RUN mode, removal just prints.

_install_docker_stub() {
  # Writes a docker stub that emits a fixed image list and records rmi calls.
  local stub_dir="$TEST_TMP/bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker for prune-protect tests.
# Subcommands:
#   ps --format '{{.Image}}'          → running images (from $FAKE_RUNNING)
#   images --format ...               → image list (from $FAKE_IMAGES)
#   rmi <img>                         → append to $TEST_TMP/rmi.log, succeed
case "$1" in
  ps)
    printf '%s\n' $FAKE_RUNNING
    ;;
  images)
    printf '%s\n' $FAKE_IMAGES
    ;;
  rmi)
    shift
    echo "$@" >> "$TEST_TMP/rmi.log"
    ;;
  *)
    echo "docker stub: unhandled $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$stub_dir/docker"
  export PATH="$stub_dir:$PATH"
  export TEST_TMP
}

@test "_docker_unused_images: lists non-running, non-dangling" {
  _install_docker_stub
  export FAKE_RUNNING="ghcr.io/org/running:v1"
  export FAKE_IMAGES=$'ghcr.io/org/running:v1\nghcr.io/org/stale:v1\nghcr.io/org/other:v2'

  run _docker_unused_images
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/org/stale:v1"* ]]
  [[ "$output" == *"ghcr.io/org/other:v2"* ]]
  [[ "$output" != *"ghcr.io/org/running:v1"* ]]
}

@test "docker_prune_protected: DRY_RUN prints but does not rmi" {
  _install_docker_stub
  export FAKE_RUNNING=""
  export FAKE_IMAGES=$'ghcr.io/org/keep:v1\nghcr.io/org/drop:v1'
  : > "$TEST_TMP/rmi.log"
  export DRY_RUN=true

  run docker_prune_protected "ghcr.io/org/keep:v1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] docker rmi ghcr.io/org/drop:v1"* ]]
  # Nothing actually rmi'd
  [ ! -s "$TEST_TMP/rmi.log" ]
}

@test "docker_prune_protected: protects listed images, removes the rest" {
  _install_docker_stub
  export FAKE_RUNNING=""
  export FAKE_IMAGES=$'ghcr.io/org/keep:v1\nghcr.io/org/drop:v1\nghcr.io/org/drop:v2'
  : > "$TEST_TMP/rmi.log"
  export DRY_RUN=false

  run docker_prune_protected "ghcr.io/org/keep:v1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Protecting 1 image(s)"* ]]
  [[ "$output" == *"ghcr.io/org/keep:v1"* ]]

  # Check rmi log
  local log
  log=$(cat "$TEST_TMP/rmi.log")
  [[ "$log" == *"ghcr.io/org/drop:v1"* ]]
  [[ "$log" == *"ghcr.io/org/drop:v2"* ]]
  [[ "$log" != *"ghcr.io/org/keep:v1"* ]]
}

@test "docker_prune_protected: no unused images → ok, no-op" {
  _install_docker_stub
  export FAKE_RUNNING="ghcr.io/org/only:v1"
  export FAKE_IMAGES="ghcr.io/org/only:v1"
  : > "$TEST_TMP/rmi.log"
  export DRY_RUN=false

  run docker_prune_protected
  [ "$status" -eq 0 ]
  [[ "$output" == *"No unused images to prune"* ]]
  [ ! -s "$TEST_TMP/rmi.log" ]
}

@test "docker_prune_protected: empty protect list → removes all unused" {
  _install_docker_stub
  export FAKE_RUNNING=""
  export FAKE_IMAGES=$'ghcr.io/org/a:v1\nghcr.io/org/b:v1'
  : > "$TEST_TMP/rmi.log"
  export DRY_RUN=false

  run docker_prune_protected
  [ "$status" -eq 0 ]
  local log
  log=$(cat "$TEST_TMP/rmi.log")
  [[ "$log" == *"ghcr.io/org/a:v1"* ]]
  [[ "$log" == *"ghcr.io/org/b:v1"* ]]
}
