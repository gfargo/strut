#!/usr/bin/env bats
# ==================================================
# tests/test_color.bats — NO_COLOR/TTY gate + brand accent
# ==================================================
# Run:  bats tests/test_color.bats
# Covers: lib/utils.sh color gate (RED/GREEN/YELLOW/BLUE/BRAND/NC), log(),
# print_banner() emitting no escapes when color is off.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

_load_utils() {
  source "$CLI_ROOT/lib/utils.sh"
}

# ── Non-TTY: bats always captures via a pipe, so [ -t 1 ] / [ -t 2 ] are false ─

@test "color vars are empty when not a TTY (NO_COLOR unset)" {
  unset NO_COLOR
  _load_utils
  [ -z "$RED" ]
  [ -z "$GREEN" ]
  [ -z "$YELLOW" ]
  [ -z "$BLUE" ]
  [ -z "$BRAND" ]
  [ -z "$NC" ]
}

@test "color vars are empty when NO_COLOR is set" {
  export NO_COLOR=1
  _load_utils
  [ -z "$RED" ]
  [ -z "$GREEN" ]
  [ -z "$YELLOW" ]
  [ -z "$BLUE" ]
  [ -z "$BRAND" ]
  [ -z "$NC" ]
}

@test "log() emits no raw escape sequences when not a TTY" {
  _load_utils
  result=$(log "hello world")
  [[ "$result" != *$'\033['* ]]
  [[ "$result" == *"[strut]"* ]]
}

@test "print_banner() emits no raw escape sequences when not a TTY" {
  _load_utils
  result=$(print_banner "Test Deploy")
  [[ "$result" != *$'\033['* ]]
  [[ "$result" == *"╔"* ]]
}

# ── Forced-TTY: use `script` to allocate a real pty so [ -t 1 ] is true ───────
# bats' own capture is always a pipe, so the gate's TTY branch can't be
# exercised directly — `script -qec` runs the command attached to a pty
# regardless of the parent's own stdio, letting us assert the "on" branch.

@test "color vars are set and BRAND differs from BLUE when a real TTY is attached" {
  if ! command -v script >/dev/null 2>&1; then
    skip "script(1) not available to simulate a TTY"
  fi

  result=$(script -qec "bash -c 'source \"$CLI_ROOT/lib/utils.sh\"; printf \"RED=[%s] BRAND=[%s] BLUE=[%s] NC=[%s]\" \"\$RED\" \"\$BRAND\" \"\$BLUE\" \"\$NC\"'" /dev/null)

  [[ "$result" != *"RED=[]"* ]]
  [[ "$result" != *"NC=[]"* ]]
  [[ "$result" != *"BRAND=[]"* ]]
  # BRAND must differ from BLUE — a distinct brand accent, not the generic blue.
  brand_val="${result#*BRAND=[}"; brand_val="${brand_val%%]*}"
  blue_val="${result#*BLUE=[}"; blue_val="${blue_val%%]*}"
  [ "$brand_val" != "$blue_val" ]
}

@test "NO_COLOR wins even with a real TTY attached" {
  if ! command -v script >/dev/null 2>&1; then
    skip "script(1) not available to simulate a TTY"
  fi

  result=$(NO_COLOR=1 script -qec "bash -c 'source \"$CLI_ROOT/lib/utils.sh\"; printf \"RED=[%s] BRAND=[%s]\" \"\$RED\" \"\$BRAND\"'" /dev/null)

  [[ "$result" == *"RED=[]"* ]]
  [[ "$result" == *"BRAND=[]"* ]]
}

@test "color vars are empty when stdout is redirected even though stderr is a TTY" {
  # Regression test: `strut ... > deploy.log` from an interactive shell leaves
  # stderr attached to the tty while stdout goes to a real file. The gate must
  # key off stdout (-t 1) alone, or log()/ok()/warn() leak escape sequences
  # into the redirected file.
  if ! command -v script >/dev/null 2>&1; then
    skip "script(1) not available to simulate a TTY"
  fi

  out_file="$BATS_TEST_TMPDIR/deploy.log"
  script -qec "bash -c 'source \"$CLI_ROOT/lib/utils.sh\"; printf \"RED=[%s] BRAND=[%s]\" \"\$RED\" \"\$BRAND\"' > \"$out_file\"" /dev/null

  result="$(cat "$out_file")"
  [[ "$result" == *"RED=[]"* ]]
  [[ "$result" == *"BRAND=[]"* ]]
}
