#!/usr/bin/env bats
# ==================================================
# tests/test_rollback_diff.bats — `strut <stack> rollback diff` coverage
# ==================================================
# Covers:
#   rollback_list_snapshot_files    (ordering)
#   rollback_resolve_ref            (HEAD / HEAD~N / basename / missing)
#   rollback_snapshot_image_pairs   (jq-backed extraction)
#   _rollback_diff                  (end-to-end text + json)
#
# jq is required for rollback diff — tests skip gracefully when it's
# missing so CI on minimal images doesn't explode.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/diff.sh"
  source "$CLI_ROOT/lib/rollback.sh"
  source "$CLI_ROOT/lib/cmd_rollback.sh"

  # _rollback_diff re-sources via $LIB — point it at our lib/ dir.
  export LIB="$CLI_ROOT/lib"

  # Sandbox snapshot dirs under TEST_TMP by overriding _rollback_dir.
  export SANDBOX_ROOT="$TEST_TMP/sandbox"
  mkdir -p "$SANDBOX_ROOT"
  eval '
_rollback_dir() {
  echo "$SANDBOX_ROOT/stacks/$1/.rollback"
}'
}

teardown() {
  common_teardown
  unset SANDBOX_ROOT LIB
}

_require_jq() {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

# Helper: write a snapshot at a specific timestamp with a list of svc=img pairs.
#   _write_snap <stack> <file-basename> <iso-ts> <svc1=img1> [<svc2=img2> …]
_write_snap() {
  local stack="$1" base="$2" ts="$3"; shift 3
  local dir="$SANDBOX_ROOT/stacks/$stack/.rollback"
  mkdir -p "$dir"
  local file="$dir/$base.json"

  local services="{" first=true
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    if $first; then first=false; else services+=","; fi
    services+="\"$key\":{\"image\":\"$val\"}"
  done
  services+="}"

  cat > "$file" <<EOF
{
  "timestamp": "$ts",
  "stack": "$stack",
  "env": "test",
  "service_count": $#,
  "services": $services
}
EOF
  echo "$file"
}

# ── rollback_list_snapshot_files ─────────────────────────────────────────────

@test "list_snapshot_files: empty dir → no output" {
  run rollback_list_snapshot_files "empty-stack"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list_snapshot_files: returns newest first" {
  local stack="lst-$$"
  # Create in timestamp-order; ls -t uses mtime so sleep between creates.
  _write_snap "$stack" "old"   "2026-04-19T12:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "mid"   "2026-04-20T09:00:00Z" "api=v2" >/dev/null
  sleep 1
  _write_snap "$stack" "new"   "2026-04-20T14:00:00Z" "api=v3" >/dev/null

  run rollback_list_snapshot_files "$stack"
  [ "$status" -eq 0 ]

  # First line should be the newest.
  local first
  first=$(echo "$output" | head -1)
  [[ "$first" == *"new.json" ]]
  local last
  last=$(echo "$output" | tail -1)
  [[ "$last" == *"old.json" ]]
}

# ── rollback_resolve_ref ─────────────────────────────────────────────────────

@test "resolve_ref: HEAD returns newest" {
  local stack="hd-$$"
  _write_snap "$stack" "a" "2026-04-19T00:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "b" "2026-04-20T00:00:00Z" "api=v2" >/dev/null

  run rollback_resolve_ref "$stack" "HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"b.json" ]]
}

@test "resolve_ref: HEAD~1 returns previous" {
  local stack="hd1-$$"
  _write_snap "$stack" "a" "2026-04-19T00:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "b" "2026-04-20T00:00:00Z" "api=v2" >/dev/null

  run rollback_resolve_ref "$stack" "HEAD~1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.json" ]]
}

@test "resolve_ref: basename with or without .json suffix" {
  local stack="bn-$$"
  _write_snap "$stack" "my-snap" "2026-04-20T00:00:00Z" "api=v1" >/dev/null

  run rollback_resolve_ref "$stack" "my-snap"
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-snap.json" ]]

  run rollback_resolve_ref "$stack" "my-snap.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-snap.json" ]]
}

@test "resolve_ref: unknown basename errors" {
  local stack="un-$$"
  _write_snap "$stack" "exists" "2026-04-20T00:00:00Z" "api=v1" >/dev/null

  run rollback_resolve_ref "$stack" "does-not-exist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"snapshot not found"* ]]
}

@test "resolve_ref: HEAD with no snapshots errors" {
  run rollback_resolve_ref "ghost-stack" "HEAD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no snapshots"* ]]
}

@test "resolve_ref: HEAD~N out of range errors" {
  local stack="or-$$"
  _write_snap "$stack" "only" "2026-04-20T00:00:00Z" "api=v1" >/dev/null

  run rollback_resolve_ref "$stack" "HEAD~5"
  [ "$status" -ne 0 ]
  [[ "$output" == *"out of range"* ]]
}

# ── rollback_snapshot_image_pairs ────────────────────────────────────────────

@test "snapshot_image_pairs: extracts service/image via jq" {
  _require_jq
  local stack="ip-$$"
  local file
  file=$(_write_snap "$stack" "s" "2026-04-20T00:00:00Z" \
    "api=ghcr.io/org/api:v1" "worker=ghcr.io/org/worker:v2")

  run rollback_snapshot_image_pairs "$file"
  [ "$status" -eq 0 ]
  # Fields separated by US (0x1f). Use printf to build the expected rows.
  local us_api
  us_api=$(printf 'api\x1fghcr.io/org/api:v1')
  local us_worker
  us_worker=$(printf 'worker\x1fghcr.io/org/worker:v2')
  [[ "$output" == *"$us_api"* ]]
  [[ "$output" == *"$us_worker"* ]]
}

# ── _rollback_diff (end-to-end) ──────────────────────────────────────────────

@test "rollback diff: identical snapshots → exit 0, no change" {
  _require_jq
  local stack="id-$$"
  _write_snap "$stack" "a" "2026-04-19T00:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "b" "2026-04-20T00:00:00Z" "api=v1" >/dev/null

  run _rollback_diff "$stack" "a" "b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"identical"* ]]
}

@test "rollback diff: image bump → CHANGE row, exit 1" {
  _require_jq
  local stack="ch-$$"
  _write_snap "$stack" "a" "2026-04-19T00:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "b" "2026-04-20T00:00:00Z" "api=v2" >/dev/null

  run _rollback_diff "$stack" "a" "b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"api"* ]]
  [[ "$output" == *"v1"* ]]
  [[ "$output" == *"v2"* ]]
  [[ "$output" == *"→"* ]] || [[ "$output" == *"->"* ]]
}

@test "rollback diff: service added in newer snapshot → ADD" {
  _require_jq
  local stack="ad-$$"
  _write_snap "$stack" "a" "2026-04-19T00:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "b" "2026-04-20T00:00:00Z" "api=v1" "new-svc=ghcr.io/org/new:v1" >/dev/null

  run _rollback_diff "$stack" "a" "b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"new-svc"* ]]
  [[ "$output" == *"+"* ]]
}

@test "rollback diff: service removed in newer snapshot → REMOVE" {
  _require_jq
  local stack="rm-$$"
  _write_snap "$stack" "a" "2026-04-19T00:00:00Z" "api=v1" "gone=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "b" "2026-04-20T00:00:00Z" "api=v1" >/dev/null

  run _rollback_diff "$stack" "a" "b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gone"* ]]
  [[ "$output" == *"-"* ]]
}

@test "rollback diff: HEAD~1 HEAD shortcut resolves correctly" {
  _require_jq
  local stack="sh-$$"
  _write_snap "$stack" "old" "2026-04-19T00:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "new" "2026-04-20T00:00:00Z" "api=v2" >/dev/null

  run _rollback_diff "$stack" "HEAD~1" "HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"old → new"* ]]
  [[ "$output" == *"api"* ]]
}

@test "rollback diff: --json output is structured" {
  _require_jq
  local stack="js-$$"
  _write_snap "$stack" "a" "2026-04-19T00:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "b" "2026-04-20T00:00:00Z" "api=v2" >/dev/null

  run _rollback_diff "$stack" "a" "b" --json
  [ "$status" -eq 1 ]
  # Validate structure with jq
  run bash -c "
    source '$CLI_ROOT/lib/utils.sh'
    fail() { echo \"\$1\" >&2; return 1; }
    source '$CLI_ROOT/lib/output.sh'
    source '$CLI_ROOT/lib/diff.sh'
    source '$CLI_ROOT/lib/rollback.sh'
    source '$CLI_ROOT/lib/cmd_rollback.sh'
    eval '
_rollback_dir() {
  echo \"$SANDBOX_ROOT/stacks/\$1/.rollback\"
}'
    LIB='$CLI_ROOT/lib' _rollback_diff '$stack' a b --json
  "
  [[ "$output" == *'"stack"'* ]]
  [[ "$output" == *'"from"'* ]]
  [[ "$output" == *'"to"'* ]]
  [[ "$output" == *'"images"'* ]]
  [[ "$output" == *'"has_changes"'* ]]
  [[ "$output" == *'"CHANGE"'* ]]

  # Validate it parses as JSON
  echo "$output" | jq . >/dev/null
}

@test "rollback diff: missing ref returns exit 2" {
  _require_jq
  local stack="ms-$$"
  _write_snap "$stack" "only" "2026-04-20T00:00:00Z" "api=v1" >/dev/null

  run _rollback_diff "$stack" "only" "does-not-exist"
  [ "$status" -eq 2 ]
}

@test "rollback diff: fewer than two refs errors with usage" {
  run _rollback_diff "some-stack"
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires two snapshot refs"* ]]
}

# ── dispatch: cmd_rollback routes `diff` subcommand ──────────────────────────

@test "cmd_rollback: dispatches 'diff' before --list" {
  _require_jq
  local stack="dp-$$"
  export CMD_STACK="$stack"
  export CMD_STACK_DIR="$SANDBOX_ROOT/stacks/$stack"
  export CMD_ENV_FILE=""
  export CMD_ENV_NAME=""
  export CMD_SERVICES=""
  mkdir -p "$CMD_STACK_DIR"

  _write_snap "$stack" "a" "2026-04-19T00:00:00Z" "api=v1" >/dev/null
  sleep 1
  _write_snap "$stack" "b" "2026-04-20T00:00:00Z" "api=v2" >/dev/null

  run cmd_rollback diff "a" "b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"api"* ]]

  unset CMD_STACK CMD_STACK_DIR CMD_ENV_FILE CMD_ENV_NAME CMD_SERVICES
}
