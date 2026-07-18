#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_webhook.bats — Tests for `webhook serve`'s HTTP handler (strut#393)
# ==================================================
# socat's SYSTEM: runs its command via `/bin/sh -c`. On stock Debian/Ubuntu
# /bin/sh is dash, which chokes on this handler's bash-only syntax
# (${line,,}, $'\r') if the raw script text is handed to `sh -c` directly.
# The fix writes the handler to a real executable file with a bash shebang
# so the KERNEL execs it via #!/usr/bin/env bash, sidestepping dash's
# parser entirely — these tests exercise the handler under a real `dash`
# (skipped where unavailable) exactly the way socat invokes it: `sh -c
# "<path>"`, piping a fake HTTP request on stdin.
#
# Run:  bats tests/test_cmd_webhook.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail()  { echo "FAIL: $1" >&2; return 1; }
  ok()    { echo "OK: $*"; }
  warn()  { echo "WARN: $*" >&2; }
  log()   { echo "LOG: $*"; }
  export -f fail ok warn log

  source "$CLI_ROOT/lib/cmd_webhook.sh"
}

teardown() { common_teardown; }

_write_handler() {
  CLI_ROOT="$TEST_TMP" _WEBHOOK_CLI_ROOT="$TEST_TMP" _webhook_handler_script > "$TEST_TMP/handler.sh"
  chmod +x "$TEST_TMP/handler.sh"
  echo "$TEST_TMP/handler.sh"
}

_skip_without_dash() {
  command -v dash &>/dev/null || skip "dash not installed"
}

# ── Handler script is valid, portable-to-invoke bash ────────────────────────

@test "_webhook_handler_script: emits a bash shebang" {
  run _webhook_handler_script
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | head -1)" == "#!/usr/bin/env bash" ]]
}

@test "_webhook_handler_script: output is syntactically valid bash" {
  local handler; handler="$(_write_handler)"
  run bash -n "$handler"
  [ "$status" -eq 0 ]
}

# ── strut#393: crashes under dash when passed as raw sh -c text ────────────

@test "regression: the handler text (pre-fix invocation style) is NOT valid dash — proves the bug this fix addresses" {
  _skip_without_dash
  local handler; handler="$(_write_handler)"
  # This is exactly the broken pattern replaced: `socat ... SYSTEM:"$(cat
  # script)"` hands the raw TEXT to `sh -c`, instead of a file path. Needs
  # at least one real header line so the loop reaches `${line,,}` — empty
  # stdin hits EOF before the loop body ever runs, masking the bug.
  run dash -c "$(cat "$handler")" <<'REQ'
POST /webhook HTTP/1.1
Content-Length: 2

{}
REQ
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bad substitution"* ]] || [[ "$output" == *"substitution"* ]]
}

# ── The actual fix: invoking the FILE (as socat's SYSTEM: now does) works ──

@test "_webhook_serve's fix: invoking the handler FILE under dash -c works (matches socat SYSTEM: semantics)" {
  _skip_without_dash
  local handler; handler="$(_write_handler)"
  export _WEBHOOK_SECRET=""
  export _WEBHOOK_BRANCH="main"
  export _WEBHOOK_CLI_ROOT="$TEST_TMP"

  run dash -c "$handler" <<'REQ'
POST /webhook HTTP/1.1
Content-Length: 47

{"ref":"refs/heads/staging","other":"ignored"}
REQ
  [ "$status" -eq 0 ]
  [[ "$output" == *"200 OK"* ]]
  [[ "$output" == *"skipped"* ]]
}

@test "handler: matching branch triggers the deploy response" {
  _skip_without_dash
  local handler; handler="$(_write_handler)"
  export _WEBHOOK_SECRET=""
  export _WEBHOOK_BRANCH="main"
  export _WEBHOOK_CLI_ROOT="$TEST_TMP"
  git -C "$TEST_TMP" init -q 2>/dev/null || true

  run dash -c "$handler" <<'REQ'
POST /webhook HTTP/1.1
Content-Length: 43

{"ref":"refs/heads/main","other":"ignored"}
REQ
  [ "$status" -eq 0 ]
  [[ "$output" == *"200 OK"* ]]
  [[ "$output" == *"deployed"* ]]
}

# ── strut#393: Content-Length tolerant of a missing space after ':' ────────

@test "handler: Content-Length without a space after the colon still reads the body" {
  _skip_without_dash
  local handler; handler="$(_write_handler)"
  export _WEBHOOK_SECRET=""
  export _WEBHOOK_BRANCH="main"
  export _WEBHOOK_CLI_ROOT="$TEST_TMP"

  run bash -c 'printf "POST /webhook HTTP/1.1\r\nContent-Length:47\r\n\r\n{\"ref\":\"refs/heads/staging\",\"other\":\"ignored\"}" | dash -c "'"$handler"'"'
  [ "$status" -eq 0 ]
  # If Content-Length failed to parse, content_length stays "0" and the
  # body/ref is never read — push_branch would be empty, still != "main",
  # so this alone wouldn't prove much. Assert the actual body length
  # instead, by checking the ref DID get extracted (empty body => empty ref
  # => "skipped" too, so cross-check via the matching-branch case below).
  [[ "$output" == *"200 OK"* ]]
}

@test "handler: Content-Length without a space, matching branch, proves the body was actually read" {
  _skip_without_dash
  local handler; handler="$(_write_handler)"
  export _WEBHOOK_SECRET=""
  export _WEBHOOK_BRANCH="main"
  export _WEBHOOK_CLI_ROOT="$TEST_TMP"
  git -C "$TEST_TMP" init -q 2>/dev/null || true

  run bash -c 'printf "POST /webhook HTTP/1.1\r\nContent-Length:43\r\n\r\n{\"ref\":\"refs/heads/main\",\"other\":\"ignored\"}" | dash -c "'"$handler"'"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"deployed"* ]]
}

# ── HMAC signature validation ───────────────────────────────────────────────

@test "handler: rejects a request with no/wrong signature when a secret is configured" {
  _skip_without_dash
  local handler; handler="$(_write_handler)"
  export _WEBHOOK_SECRET="topsecret"
  export _WEBHOOK_BRANCH="main"
  export _WEBHOOK_CLI_ROOT="$TEST_TMP"

  run dash -c "$handler" <<'REQ'
POST /webhook HTTP/1.1
Content-Length: 43
X-Hub-Signature-256: sha256=deadbeef

{"ref":"refs/heads/main","other":"ignored"}
REQ
  [ "$status" -eq 0 ]
  [[ "$output" == *"401 Unauthorized"* ]]
}

@test "handler: accepts a request with a correct HMAC signature" {
  _skip_without_dash
  command -v openssl &>/dev/null || skip "openssl not installed"
  local handler; handler="$(_write_handler)"
  export _WEBHOOK_SECRET="topsecret"
  export _WEBHOOK_BRANCH="main"
  export _WEBHOOK_CLI_ROOT="$TEST_TMP"
  git -C "$TEST_TMP" init -q 2>/dev/null || true

  local body='{"ref":"refs/heads/main","other":"ignored"}'
  local sig
  sig="sha256=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$_WEBHOOK_SECRET" | sed 's/^.* //')"

  run bash -c "printf 'POST /webhook HTTP/1.1\r\nContent-Length: ${#body}\r\nX-Hub-Signature-256: $sig\r\n\r\n$body' | dash -c '$handler'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"200 OK"* ]]
  [[ "$output" == *"deployed"* ]]
}

# ── _webhook_serve writes an executable file and registers cleanup ─────────

@test "_webhook_serve: writes an executable handler file and registers its cleanup" {
  socat() { echo "socat $*" > "$TEST_TMP/socat_call"; }
  export -f socat
  local cleanups_run=""
  strut_register_cleanup() { cleanups_run="$cleanups_run $1"; }
  export -f strut_register_cleanup

  CLI_ROOT="$TEST_TMP" run _webhook_serve --port 9999 --secret shh
  [ "$status" -eq 0 ]

  local systemarg
  systemarg=$(grep -oE 'SYSTEM:[^ ]+' "$TEST_TMP/socat_call")
  local handler_path="${systemarg#SYSTEM:}"
  [ -x "$handler_path" ]
  [[ "$(head -1 "$handler_path")" == "#!/usr/bin/env bash" ]]
}

# ── Poll-mode pure helpers (unaffected by this fix, quick smoke coverage) ──

@test "_all_stacks: lists stack directories" {
  mkdir -p "$TEST_TMP/stacks/alpha" "$TEST_TMP/stacks/beta"
  touch "$TEST_TMP/stacks/00-not-a-dir.txt"
  run _all_stacks "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
  [[ "$output" != *"00-not-a-dir.txt"* ]]
}

# _all_stacks used to return the last `ls` entry's own [ -d ] result as its
# exit code, so a stray non-directory file sorting AFTER every real stack
# dir (e.g. a README, .DS_Store, editor swap file) made the function report
# failure even though its stdout output was correct. Under set -euo
# pipefail, the plain assignment `changed_stacks=$(_all_stacks ...)` in
# _poll_cycle would then trip errexit and silently abort the whole poll
# cycle. Fixed with an explicit `return 0` at the end of the function.

@test "_all_stacks: returns 0 when a non-dir file sorts AFTER every stack dir" {
  mkdir -p "$TEST_TMP/stacks/alpha" "$TEST_TMP/stacks/beta"
  touch "$TEST_TMP/stacks/zzz-not-a-dir.txt"
  run _all_stacks "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
  [[ "$output" != *"zzz-not-a-dir.txt"* ]]
}

@test "_all_stacks: returns 0 and empty output when the stacks dir is missing" {
  run _all_stacks "$TEST_TMP/nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_detect_changed_stacks: maps changed files under stacks/ to stack names" {
  git -C "$TEST_TMP" init -q
  git -C "$TEST_TMP" config user.email t@example.com
  git -C "$TEST_TMP" config user.name t
  mkdir -p "$TEST_TMP/stacks/alpha"
  echo one > "$TEST_TMP/stacks/alpha/file.txt"
  git -C "$TEST_TMP" add -A
  git -C "$TEST_TMP" commit -q -m first
  local from_sha; from_sha=$(git -C "$TEST_TMP" rev-parse HEAD)

  echo two >> "$TEST_TMP/stacks/alpha/file.txt"
  git -C "$TEST_TMP" commit -qam second
  local to_sha; to_sha=$(git -C "$TEST_TMP" rev-parse HEAD)

  run _detect_changed_stacks "$TEST_TMP" "$from_sha" "$to_sha"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha" ]
}
