#!/usr/bin/env bats
# ==================================================
# tests/test_diff.bats — Tests for lib/diff.sh semantic diff engine
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/diff.sh"
}

teardown() {
  common_teardown
}

# ── _diff_normalize_env ───────────────────────────────────────────────────────

@test "_diff_normalize_env: strips comments and blank lines" {
  result=$(_diff_normalize_env $'# hello\n\nFOO=bar')
  [ "$result" = "FOO=bar" ]
}

@test "_diff_normalize_env: strips surrounding double quotes" {
  result=$(_diff_normalize_env 'FOO="bar"')
  [ "$result" = "FOO=bar" ]
}

@test "_diff_normalize_env: strips surrounding single quotes" {
  result=$(_diff_normalize_env "FOO='bar'")
  [ "$result" = "FOO=bar" ]
}

@test "_diff_normalize_env: preserves unquoted values as-is" {
  result=$(_diff_normalize_env 'FOO=bar baz')
  [ "$result" = "FOO=bar baz" ]
}

@test "_diff_normalize_env: sorts keys" {
  result=$(_diff_normalize_env $'ZEBRA=1\nAPPLE=2\nMONKEY=3')
  [ "$result" = $'APPLE=2\nMONKEY=3\nZEBRA=1' ]
}

@test "_diff_normalize_env: strips export prefix" {
  result=$(_diff_normalize_env 'export FOO=bar')
  [ "$result" = "FOO=bar" ]
}

@test "_diff_normalize_env: preserves = inside value" {
  result=$(_diff_normalize_env 'CONN=postgres://u:p@h/db?opt=1')
  [ "$result" = "CONN=postgres://u:p@h/db?opt=1" ]
}

# ── diff_env_content ──────────────────────────────────────────────────────────

@test "diff_env_content: identical content → empty output" {
  local same=$'FOO=1\nBAR=2'
  result=$(diff_env_content "$same" "$same")
  [ -z "$result" ]
}

@test "diff_env_content: added key produces ADD row" {
  result=$(diff_env_content $'FOO=1\nNEW=x' 'FOO=1')
  [[ "$result" == *$'ADD\x1fNEW\x1f\x1fx'* ]]
}

@test "diff_env_content: removed key produces REMOVE row" {
  result=$(diff_env_content 'FOO=1' $'FOO=1\nOLD=y')
  [[ "$result" == *$'REMOVE\x1fOLD\x1fy\x1f'* ]]
}

@test "diff_env_content: changed key produces CHANGE row with old→new" {
  result=$(diff_env_content 'FOO=new' 'FOO=old')
  [[ "$result" == *$'CHANGE\x1fFOO\x1fold\x1fnew'* ]]
}

@test "diff_env_content: multiple changes all appear" {
  local local_env=$'KEEP=same\nCHANGE=new\nADD=v'
  local remote_env=$'KEEP=same\nCHANGE=old\nGONE=x'
  result=$(diff_env_content "$local_env" "$remote_env")
  [[ "$result" == *"ADD"*"ADD"* ]]      # ADD op for ADD key
  [[ "$result" == *"REMOVE"*"GONE"* ]]
  [[ "$result" == *"CHANGE"*"CHANGE"* ]]
  # KEEP should not appear in output
  [[ "$result" != *"KEEP"* ]]
}

@test "diff_env_content: ignores quoting differences" {
  # Remote quoted, local unquoted — same semantic value
  result=$(diff_env_content 'FOO=bar' 'FOO="bar"')
  [ -z "$result" ]
}

@test "diff_env_content: ignores comments in both sides" {
  result=$(diff_env_content $'# local\nFOO=1' $'# remote\nFOO=1')
  [ -z "$result" ]
}

@test "diff_env_content: empty remote means every local key is ADD" {
  result=$(diff_env_content $'FOO=1\nBAR=2' "")
  # Two ADD lines
  local count
  count=$(echo "$result" | grep -c "^ADD")
  [ "$count" -eq 2 ]
}

@test "diff_env_content: empty local means every remote key is REMOVE" {
  result=$(diff_env_content "" $'FOO=1\nBAR=2')
  local count
  count=$(echo "$result" | grep -c "^REMOVE")
  [ "$count" -eq 2 ]
}

# ── diff_extract_images ───────────────────────────────────────────────────────

@test "diff_extract_images: extracts service→image mapping" {
  local compose='services:
  api:
    image: myorg/api:v1.2.3
  worker:
    image: myorg/worker:latest
'
  result=$(diff_extract_images "$compose")
  [[ "$result" == *$'api\x1fmyorg/api:v1.2.3'* ]]
  [[ "$result" == *$'worker\x1fmyorg/worker:latest'* ]]
}

@test "diff_extract_images: strips quotes around image value" {
  local compose='services:
  api:
    image: "myorg/api:v1"
'
  result=$(diff_extract_images "$compose")
  [[ "$result" == *$'api\x1fmyorg/api:v1'* ]]
}

@test "diff_extract_images: ignores services without image" {
  local compose='services:
  api:
    build: .
'
  result=$(diff_extract_images "$compose")
  [ -z "$result" ]
}

@test "diff_extract_images: stops extraction at end of services block" {
  local compose='services:
  api:
    image: a:1
volumes:
  data:
    driver: local
'
  result=$(diff_extract_images "$compose")
  [[ "$result" == *$'api\x1fa:1'* ]]
  # Should not emit a spurious `data\x1f` row
  [[ "$result" != *"data"* ]]
}

# ── diff_images_content ───────────────────────────────────────────────────────

@test "diff_images_content: image tag change produces CHANGE row" {
  local loc='services:
  api:
    image: myorg/api:v2
'
  local rem='services:
  api:
    image: myorg/api:v1
'
  result=$(diff_images_content "$loc" "$rem")
  [[ "$result" == *$'CHANGE\x1fapi\x1fmyorg/api:v1\x1fmyorg/api:v2'* ]]
}

@test "diff_images_content: new service → ADD" {
  local loc='services:
  api:
    image: a:1
  worker:
    image: w:1
'
  local rem='services:
  api:
    image: a:1
'
  result=$(diff_images_content "$loc" "$rem")
  [[ "$result" == *$'ADD\x1fworker\x1f\x1fw:1'* ]]
}

@test "diff_images_content: removed service → REMOVE" {
  local loc='services:
  api:
    image: a:1
'
  local rem='services:
  api:
    image: a:1
  worker:
    image: w:1
'
  result=$(diff_images_content "$loc" "$rem")
  [[ "$result" == *$'REMOVE\x1fworker\x1fw:1\x1f'* ]]
}

@test "diff_images_content: identical images → empty" {
  local same='services:
  api:
    image: a:1
'
  result=$(diff_images_content "$same" "$same")
  [ -z "$result" ]
}

# ── _diff_render_section_text ────────────────────────────────────────────────

@test "_diff_render_section_text: ADD rendered with + prefix" {
  local tsv=$'ADD\x1fFOO\x1f\x1fbar'
  result=$(_diff_render_section_text "Env" "$tsv")
  [[ "$result" == *"+ FOO=bar"* ]]
}

@test "_diff_render_section_text: REMOVE rendered with - prefix" {
  local tsv=$'REMOVE\x1fGONE\x1fold\x1f'
  result=$(_diff_render_section_text "Env" "$tsv")
  [[ "$result" == *"- GONE"* ]]
}

@test "_diff_render_section_text: CHANGE rendered with ~ prefix and arrow" {
  local tsv=$'CHANGE\x1fFOO\x1fold\x1fnew'
  result=$(_diff_render_section_text "Env" "$tsv")
  [[ "$result" == *"~ FOO: old → new"* ]]
}

@test "_diff_render_section_text: empty tsv → no output" {
  result=$(_diff_render_section_text "Env" "")
  [ -z "$result" ]
}

@test "_diff_render_section_text: pluralizes change count" {
  local tsv=$'ADD\x1fA\x1f\x1f1\nADD\x1fB\x1f\x1f2'
  result=$(_diff_render_section_text "Env" "$tsv")
  [[ "$result" == *"(2 changes)"* ]]
}

@test "_diff_render_section_text: singular for one change" {
  local tsv=$'ADD\x1fA\x1f\x1f1'
  result=$(_diff_render_section_text "Env" "$tsv")
  [[ "$result" == *"(1 change)"* ]]
}

# ── _diff_render_section_json ────────────────────────────────────────────────

@test "_diff_render_section_json: emits array of objects" {
  OUTPUT_MODE=json
  local tsv=$'ADD\x1fFOO\x1f\x1fbar'
  result=$(_diff_render_section_json "env_vars" "$tsv")
  [[ "$result" == *'"env_vars"'*'['* ]]
  [[ "$result" == *'"op":"ADD"'* ]]
  [[ "$result" == *'"key":"FOO"'* ]]
  [[ "$result" == *'"new":"bar"'* ]]
}

@test "_diff_render_section_json: empty tsv → empty array" {
  OUTPUT_MODE=json
  result=$(_diff_render_section_json "env_vars" "")
  [[ "$result" == *'"env_vars"'*'['*']'* ]]
}

@test "_diff_render_section_json: CHANGE has both old and new" {
  OUTPUT_MODE=json
  local tsv=$'CHANGE\x1fFOO\x1fold\x1fnew'
  result=$(_diff_render_section_json "env_vars" "$tsv")
  [[ "$result" == *'"old":"old"'* ]]
  [[ "$result" == *'"new":"new"'* ]]
}
