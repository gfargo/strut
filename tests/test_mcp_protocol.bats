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

@test "responses use newline-delimited JSON (MCP stdio transport spec)" {
  local msg='{"jsonrpc":"2.0","id":1,"method":"ping"}'
  local infile="$TEST_TMP/in"
  printf '%s\n' "$msg" > "$infile"

  local outfile="$TEST_TMP/out"
  _serve "$infile" > "$outfile"
  # Output must be a single JSON line ending with newline
  local line_count
  line_count=$(wc -l < "$outfile" | tr -d ' ')
  [ "$line_count" -eq 1 ]
  # Must be valid JSON
  jq empty < "$outfile"
  [[ "$(cat "$outfile")" == *'"jsonrpc":"2.0"'* ]]
}

@test "response is a complete JSON object on one line (no Content-Length headers)" {
  local msg='{"jsonrpc":"2.0","id":1,"method":"ping"}'
  local infile="$TEST_TMP/in"
  printf '%s\n' "$msg" > "$infile"

  local outfile="$TEST_TMP/out"
  _serve "$infile" > "$outfile"
  # Must NOT contain Content-Length header
  [[ "$(cat "$outfile")" != *"Content-Length"* ]]
  # Must be parseable as JSON-RPC response
  local result_id
  result_id=$(jq -r '.id' < "$outfile")
  [ "$result_id" = "1" ]
}

@test "live open-pipe handshake returns tools/list as one JSON line" {
  command -v node >/dev/null 2>&1 || skip "node is required for persistent stdio integration test"

  run node - "$CLI_ROOT/strut" <<'NODE'
const path = require("node:path");
const { spawn } = require("node:child_process");

const strut = process.argv[2];
const child = spawn(strut, ["mcp", "serve"], {
  cwd: path.dirname(strut),
  stdio: ["pipe", "pipe", "pipe"],
});

let buffer = "";
let stderr = "";
let done = false;
const timer = setTimeout(() => finish("timed out waiting for tools/list"), 5000);

function finish(error) {
  if (done) return;
  done = true;
  clearTimeout(timer);
  child.kill("SIGTERM");
  if (error) {
    console.error(`${error}${stderr ? `; stderr: ${stderr}` : ""}`);
    process.exitCode = 1;
  }
}

function send(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

child.stderr.on("data", (chunk) => {
  stderr += chunk.toString("utf8");
});

child.on("error", (error) => finish(`spawn failed: ${error.message}`));
child.on("exit", (code, signal) => {
  if (!done) finish(`server exited before tools/list: code=${code} signal=${signal}`);
});

child.stdout.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  let newline;
  while (!done && (newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);

    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      finish(`invalid newline-delimited JSON: ${error.message}`);
      return;
    }

    if (message.id === 1) {
      send({ jsonrpc: "2.0", method: "notifications/initialized" });
      send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    } else if (message.id === 2) {
      const tools = message.result && message.result.tools;
      if (!Array.isArray(tools) || tools.length === 0) {
        finish("tools/list response did not contain tools");
        return;
      }
      console.log(`tools=${tools.length}`);
      finish();
    }
  }
});

send({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "persistent-pipe-test", version: "1.0.0" },
  },
});
NODE

  [ "$status" -eq 0 ]
  [[ "$output" == *"tools="* ]]
}
