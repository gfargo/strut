#!/usr/bin/env bats
# ==================================================
# tests/test_output.bats — Tests for lib/output.sh
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"

  unset OUTPUT_MODE
  unset NO_COLOR
  out_table_reset
  out_json_reset
}

teardown() {
  common_teardown
}

# ---------- output_mode ----------

@test "output_mode: defaults to text" {
  run output_mode
  [ "$output" = "text" ]
}

@test "output_mode: json when OUTPUT_MODE=json" {
  OUTPUT_MODE=json run output_mode
  [ "$output" = "json" ]
}

@test "output_mode: unknown value falls back to text" {
  OUTPUT_MODE=xml run output_mode
  [ "$output" = "text" ]
}

# ---------- output_use_color ----------

@test "output_use_color: false when NO_COLOR set" {
  NO_COLOR=1 run output_use_color
  [ "$status" -ne 0 ]
}

@test "output_use_color: false when not a tty (run always pipes)" {
  unset NO_COLOR
  run output_use_color
  [ "$status" -ne 0 ]
}

# ---------- Table renderer ----------

@test "out_table_header + render: empty table prints header + separator" {
  out_table_header "Name" "Status"
  run out_table_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"Name"* ]]
  [[ "$output" == *"Status"* ]]
  [[ "$output" == *"---"* ]]
}

@test "out_table_row: values appear in rendered output" {
  out_table_header "Name" "Status"
  out_table_row "api" "healthy"
  out_table_row "worker" "degraded"
  run out_table_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"api"* ]]
  [[ "$output" == *"healthy"* ]]
  [[ "$output" == *"worker"* ]]
  [[ "$output" == *"degraded"* ]]
}

@test "out_table_row: widens column when value longer than header" {
  out_table_header "N" "S"
  out_table_row "longer-name" "x"
  run out_table_render
  [ "$status" -eq 0 ]
  # The separator line width should reflect the expanded column
  [[ "$output" == *"longer-name"* ]]
}

@test "out_table: json mode is a no-op" {
  OUTPUT_MODE=json
  out_table_header "Name" "Status"
  out_table_row "api" "healthy"
  run out_table_render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "out_table_empty: renders fallback message" {
  run out_table_empty "no backups found"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no backups found"* ]]
}

@test "out_table_empty: default message when none given" {
  run out_table_empty
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no results)"* ]]
}

@test "out_table_empty: silent in json mode" {
  OUTPUT_MODE=json run out_table_empty "nothing"
  [ -z "$output" ]
}

@test "_out_strip_ansi: removes color codes for width calc" {
  run _out_strip_ansi $'\033[31mRED\033[0m'
  [ "$output" = "RED" ]
}

# ---------- JSON renderer ----------

@test "out_json_object: bare object with single field" {
  export OUTPUT_MODE=json
  run bash -c '
    source "'"$CLI_ROOT"'/lib/output.sh"
    out_json_object
      out_json_field "name" "api"
    out_json_close_object
    out_json_newline
  '
  [ "$status" -eq 0 ]
  [ "$output" = '{"name":"api"}' ]
}

@test "out_json_object: multiple fields separated by commas" {
  export OUTPUT_MODE=json
  run bash -c '
    source "'"$CLI_ROOT"'/lib/output.sh"
    out_json_object
      out_json_field "name" "api"
      out_json_field "env" "prod"
    out_json_close_object
  '
  [ "$status" -eq 0 ]
  [ "$output" = '{"name":"api","env":"prod"}' ]
}

@test "out_json_array: keyed array with string elements" {
  export OUTPUT_MODE=json
  run bash -c '
    source "'"$CLI_ROOT"'/lib/output.sh"
    out_json_object
      out_json_array "stacks"
        out_json_string "api"
        out_json_string "worker"
      out_json_close_array
    out_json_close_object
  '
  [ "$status" -eq 0 ]
  [ "$output" = '{"stacks":["api","worker"]}' ]
}

@test "out_json: nested objects inside array" {
  export OUTPUT_MODE=json
  run bash -c '
    source "'"$CLI_ROOT"'/lib/output.sh"
    out_json_object
      out_json_array "stacks"
        out_json_object
          out_json_field "name" "api"
          out_json_field "health" "ok"
        out_json_close_object
        out_json_object
          out_json_field "name" "worker"
          out_json_field "health" "down"
        out_json_close_object
      out_json_close_array
    out_json_close_object
  '
  [ "$status" -eq 0 ]
  [ "$output" = '{"stacks":[{"name":"api","health":"ok"},{"name":"worker","health":"down"}]}' ]
}

@test "out_json_field_raw: emits unquoted numeric values" {
  export OUTPUT_MODE=json
  run bash -c '
    source "'"$CLI_ROOT"'/lib/output.sh"
    out_json_object
      out_json_field_raw "count" "42"
      out_json_field_raw "enabled" "true"
    out_json_close_object
  '
  [ "$status" -eq 0 ]
  [ "$output" = '{"count":42,"enabled":true}' ]
}

@test "out_json_field: escapes double quotes" {
  export OUTPUT_MODE=json
  run bash -c '
    source "'"$CLI_ROOT"'/lib/output.sh"
    out_json_object
      out_json_field "msg" "he said \"hi\""
    out_json_close_object
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'\"hi\"'* ]]
}

@test "out_json_field: escapes backslashes" {
  export OUTPUT_MODE=json
  run bash -c '
    source "'"$CLI_ROOT"'/lib/output.sh"
    out_json_object
      out_json_field "path" "a\\b"
    out_json_close_object
  '
  [ "$status" -eq 0 ]
  # The value `a\b` → JSON `a\\b`
  [[ "$output" == *'"path":"a\\b"'* ]]
}

@test "out_json_field: escapes newlines to \\n" {
  export OUTPUT_MODE=json
  run bash -c "
    source \"$CLI_ROOT/lib/output.sh\"
    out_json_object
      out_json_field 'msg' \$'line1\\nline2'
    out_json_close_object
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'line1\nline2'* ]]
}

@test "out_json: helpers are no-ops in text mode" {
  OUTPUT_MODE=text
  run bash -c '
    source "'"$CLI_ROOT"'/lib/output.sh"
    out_json_object
      out_json_field "name" "api"
    out_json_close_object
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "out_json_reset: clears partial state" {
  OUTPUT_MODE=json
  out_json_object
  [ "${#_OUT_JSON_STACK[@]}" -gt 0 ]
  out_json_reset
  [ "${#_OUT_JSON_STACK[@]}" -eq 0 ]
}
