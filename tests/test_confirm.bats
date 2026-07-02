#!/usr/bin/env bats
# ==================================================
# test_confirm.bats — confirm() + read_or_fail() + --yes wiring
# ==================================================
# Property: interactive prompts never hang non-interactive callers.
#   1. STRUT_YES=1 → confirm returns 0 without reading stdin
#   2. Non-TTY stdin → confirm returns 1 (declines) without hanging
#   3. read_or_fail → fails loudly (exit 1) when no TTY and no value
#   4. --yes / -y flag → parse_common_flags sets STRUT_YES=1

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLI_ROOT
  # shellcheck disable=SC1091
  source "$CLI_ROOT/lib/utils.sh"
  # shellcheck disable=SC1091
  source "$CLI_ROOT/lib/flags.sh"
}

# ── confirm(): STRUT_YES bypasses the read ──────────────────────────────
@test "confirm returns 0 immediately when STRUT_YES=1 (no read)" {
  STRUT_YES=1 run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    # No stdin piped and no timeout — if confirm reads, this test hangs.
    confirm "Do the thing?" </dev/null
  '
  [ "$status" -eq 0 ]
}

@test "confirm returns 0 immediately when STRUT_YES=true (word form)" {
  STRUT_YES=true run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    confirm "Do the thing?" </dev/null
  '
  [ "$status" -eq 0 ]
}

# ── confirm(): non-TTY stdin auto-declines (fail-safe) ──────────────────
@test "confirm returns 1 without hanging when stdin is not a TTY" {
  run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    # Redirect stdin from /dev/null — non-TTY, no data. Without the fix
    # this would either hang forever or read empty and return 1 randomly.
    confirm "Continue?" </dev/null
  '
  [ "$status" -eq 1 ]
  # Should print a warning explaining why
  [[ "$output" == *"no TTY"* ]] || [[ "$output" == *"STRUT_YES"* ]]
}

# ── read_or_fail(): fails hard when non-interactive and no value ────────
@test "read_or_fail exits non-zero when non-interactive and no value provided" {
  run bash -c '
    source "'"$CLI_ROOT"'/lib/utils.sh"
    read_or_fail my_value "Enter value: " </dev/null
    echo "should not reach here"
  '
  [ "$status" -ne 0 ]
  [[ "$output" != *"should not reach here"* ]]
}

# ── flags: --yes and -y set STRUT_YES=1 ─────────────────────────────────
@test "parse_common_flags: --yes exports STRUT_YES=1" {
  unset STRUT_YES
  parse_common_flags --yes deploy --env prod
  [ "${STRUT_YES:-}" = "1" ]
}

@test "parse_common_flags: -y exports STRUT_YES=1" {
  unset STRUT_YES
  parse_common_flags -y deploy --env prod
  [ "${STRUT_YES:-}" = "1" ]
}

@test "parse_common_flags: --yes leaves other args in FLAGS_POSITIONAL" {
  unset STRUT_YES
  parse_common_flags deploy --env prod --yes some-service
  [ "${STRUT_YES:-}" = "1" ]
  [ "${FLAGS_ENV_NAME}" = "prod" ]
  [ "${#FLAGS_POSITIONAL[@]}" -eq 2 ]
  [ "${FLAGS_POSITIONAL[0]}" = "deploy" ]
  [ "${FLAGS_POSITIONAL[1]}" = "some-service" ]
}
