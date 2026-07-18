#!/usr/bin/env bats
# ==================================================
# tests/test_mcp_protocol.bats — Tests for lib/mcp/protocol.sh stdio framing
# ==================================================
# Run:  bats tests/test_mcp_protocol.bats
# Covers: strut #433 — mcp_serve must handle both raw newline-delimited JSON
# (Claude Code) and Content-Length HTTP-style framed messages (Kiro, VS Code)
# per the MCP stdio transport spec, without hanging.

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STRUT_HOME="$CLI_ROOT"
  export CLI_ROOT STRUT_HOME
  source "$CLI_ROOT/lib/mcp/protocol.sh"
  source "$CLI_ROOT/lib/mcp/tools.sh"

  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# _serve <stdin-file> — run mcp_serve in a fresh bash process reading from
# <stdin-file>. A real file (not a variable round-trip) preserves exact
# bytes, including a message's trailing newline, which command substitution
# would otherwise strip.
_serve() {
  bash -c '
    set -euo pipefail
    source "$1/lib/mcp/protocol.sh"
    source "$1/lib/mcp/tools.sh"
    export STRUT_HOME="$1"
    mcp_serve < "$2"
  ' _ "$CLI_ROOT" "$1"
}

@test "framed initialize: responds instead of hanging" {
  local msg='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
  local infile="$TEST_TMP/in"
  printf 'Content-Length: %d\r\n\r\n%s' "${#msg}" "$msg" > "$infile"

  run _serve "$infile"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"result"'* ]]
  [[ "$output" == *'"protocolVersion":"2024-11-05"'* ]]
  [[ "$output" == *'"id":1'* ]]
}

@test "raw initialize (regression): newline-delimited JSON still works" {
  local msg='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
  local infile="$TEST_TMP/in"
  printf '%s\n' "$msg" > "$infile"

  run _serve "$infile"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"result"'* ]]
  [[ "$output" == *'"protocolVersion":"2024-11-05"'* ]]
  [[ "$output" == *'"id":1'* ]]
}

@test "framed full handshake: initialize -> notifications/initialized -> tools/list" {
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
  local ack='{"jsonrpc":"2.0","method":"notifications/initialized"}'
  local list='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  local infile="$TEST_TMP/in"

  {
    printf 'Content-Length: %d\r\n\r\n%s' "${#init}" "$init"
    printf 'Content-Length: %d\r\n\r\n%s' "${#ack}" "$ack"
    printf 'Content-Length: %d\r\n\r\n%s' "${#list}" "$list"
  } > "$infile"

  run _serve "$infile"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '"jsonrpc"')" -eq 2 ]
  [[ "$output" == *'"id":1'* ]]
  [[ "$output" == *'"id":2'* ]]
  [[ "$output" == *'strut_list'* ]]
}

@test "two raw messages back-to-back: both answered" {
  local a='{"jsonrpc":"2.0","id":1,"method":"ping"}'
  local b='{"jsonrpc":"2.0","id":2,"method":"ping"}'
  local infile="$TEST_TMP/in"
  printf '%s\n%s\n' "$a" "$b" > "$infile"

  run _serve "$infile"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '"jsonrpc"')" -eq 2 ]
  [[ "$output" == *'"id":1'* ]]
  [[ "$output" == *'"id":2'* ]]
}

@test "blank lines before a raw JSON line are skipped" {
  local msg='{"jsonrpc":"2.0","id":1,"method":"ping"}'
  local infile="$TEST_TMP/in"
  printf '\n\n%s\n' "$msg" > "$infile"

  run _serve "$infile"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":1'* ]]
}

@test "framed unknown method: returns -32601" {
  local msg='{"jsonrpc":"2.0","id":1,"method":"bogus/method"}'
  local infile="$TEST_TMP/in"
  printf 'Content-Length: %d\r\n\r\n%s' "${#msg}" "$msg" > "$infile"

  run _serve "$infile"
  [ "$status" -eq 0 ]
  [[ "$output" == *'-32601'* ]]
}

@test "framed multi-byte UTF-8 body: Content-Length is a byte count, not a char count" {
  # msg's Content-Length must be its BYTE length (wc -c, locale-independent).
  # Using a char-counting read (${#msg} under a UTF-8 locale) would
  # under-consume the body and desync onto the next frame's headers.
  local msg='{"jsonrpc":"2.0","id":1,"method":"ping","params":{"note":"héllo wörld 日本語 🎉"}}'
  local next='{"jsonrpc":"2.0","id":2,"method":"ping"}'
  local infile="$TEST_TMP/in"
  local byte_len
  byte_len=$(printf '%s' "$msg" | wc -c)

  {
    printf 'Content-Length: %d\r\n\r\n%s' "$byte_len" "$msg"
    printf 'Content-Length: %d\r\n\r\n%s' "${#next}" "$next"
  } > "$infile"

  run _serve "$infile"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '"jsonrpc"')" -eq 2 ]
  [[ "$output" == *'"id":1'* ]]
  [[ "$output" == *'"id":2'* ]]
}

@test "framed message with lowercase content-length header: still parsed" {
  local msg='{"jsonrpc":"2.0","id":1,"method":"ping"}'
  local infile="$TEST_TMP/in"
  printf 'content-length: %d\r\n\r\n%s' "${#msg}" "$msg" > "$infile"

  run _serve "$infile"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":1'* ]]
}
