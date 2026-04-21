#!/usr/bin/env bats
# ==================================================
# tests/test_flags.bats — parse_common_flags helper
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/flags.sh"
}

teardown() {
  common_teardown
}

@test "parse_common_flags: no args leaves everything empty" {
  parse_common_flags
  [ "$FLAGS_ENV_NAME" = "" ]
  [ "$FLAGS_SERVICES" = "" ]
  [ "$FLAGS_JSON" = "" ]
  [ "$FLAGS_DRY_RUN" = "" ]
  [ "$FLAGS_HELP" = "" ]
  [ "${#FLAGS_POSITIONAL[@]}" -eq 0 ]
}

@test "parse_common_flags: --env name form" {
  parse_common_flags --env prod
  [ "$FLAGS_ENV_NAME" = "prod" ]
}

@test "parse_common_flags: --env=name form" {
  parse_common_flags --env=staging
  [ "$FLAGS_ENV_NAME" = "staging" ]
}

@test "parse_common_flags: --services name form" {
  parse_common_flags --services core,api
  [ "$FLAGS_SERVICES" = "core,api" ]
}

@test "parse_common_flags: --services=name form" {
  parse_common_flags --services=db,cache
  [ "$FLAGS_SERVICES" = "db,cache" ]
}

@test "parse_common_flags: --json flag" {
  parse_common_flags --json
  [ "$FLAGS_JSON" = "--json" ]
}

@test "parse_common_flags: --dry-run flag" {
  parse_common_flags --dry-run
  [ "$FLAGS_DRY_RUN" = "true" ]
}

@test "parse_common_flags: --help flag" {
  parse_common_flags --help
  [ "$FLAGS_HELP" = "true" ]
}

@test "parse_common_flags: -h short flag" {
  parse_common_flags -h
  [ "$FLAGS_HELP" = "true" ]
}

@test "parse_common_flags: mixed order" {
  parse_common_flags positional1 --env prod --json --dry-run positional2
  [ "$FLAGS_ENV_NAME" = "prod" ]
  [ "$FLAGS_JSON" = "--json" ]
  [ "$FLAGS_DRY_RUN" = "true" ]
  [ "${#FLAGS_POSITIONAL[@]}" -eq 2 ]
  [ "${FLAGS_POSITIONAL[0]}" = "positional1" ]
  [ "${FLAGS_POSITIONAL[1]}" = "positional2" ]
}

@test "parse_common_flags: unknown flag preserved in positional" {
  parse_common_flags --follow --since 1h
  [ "${#FLAGS_POSITIONAL[@]}" -eq 3 ]
  [ "${FLAGS_POSITIONAL[0]}" = "--follow" ]
  [ "${FLAGS_POSITIONAL[1]}" = "--since" ]
  [ "${FLAGS_POSITIONAL[2]}" = "1h" ]
}

@test "parse_common_flags: positional args only" {
  parse_common_flags arg1 arg2 arg3
  [ "${#FLAGS_POSITIONAL[@]}" -eq 3 ]
  [ "${FLAGS_POSITIONAL[0]}" = "arg1" ]
  [ "${FLAGS_POSITIONAL[2]}" = "arg3" ]
}

@test "parse_common_flags: all flags combined" {
  parse_common_flags --env=prod --services core --json --dry-run --help cmd
  [ "$FLAGS_ENV_NAME" = "prod" ]
  [ "$FLAGS_SERVICES" = "core" ]
  [ "$FLAGS_JSON" = "--json" ]
  [ "$FLAGS_DRY_RUN" = "true" ]
  [ "$FLAGS_HELP" = "true" ]
  [ "${#FLAGS_POSITIONAL[@]}" -eq 1 ]
  [ "${FLAGS_POSITIONAL[0]}" = "cmd" ]
}

@test "parse_common_flags: resets globals across calls" {
  parse_common_flags --env prod --json
  parse_common_flags positional
  [ "$FLAGS_ENV_NAME" = "" ]
  [ "$FLAGS_JSON" = "" ]
  [ "${FLAGS_POSITIONAL[0]}" = "positional" ]
}

@test "flags_has_help: returns 0 for --help" {
  run flags_has_help foo --help bar
  [ "$status" -eq 0 ]
}

@test "flags_has_help: returns 0 for -h" {
  run flags_has_help -h
  [ "$status" -eq 0 ]
}

@test "flags_has_help: returns 1 when absent" {
  run flags_has_help foo bar --env prod
  [ "$status" -eq 1 ]
}
