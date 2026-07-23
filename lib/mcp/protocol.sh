#!/usr/bin/env bash
# ==================================================
# lib/mcp/protocol.sh — MCP JSON-RPC protocol handler (stdio)
# ==================================================
# Reads JSON-RPC messages from stdin, dispatches to handlers, writes responses
# to stdout. Implements the Model Context Protocol for AI agent integration.

set -euo pipefail

# _mcp_read_message — read one JSON-RPC message from stdin into $REPLY.
# Supports both raw newline-delimited JSON (Claude Code) and Content-Length
# HTTP-style framing (Kiro, VS Code MCP clients) per the MCP stdio transport
# spec. Returns non-zero on EOF.
_mcp_read_message() {
  local header header_lc hdr len

  if ! IFS= read -r header; then
    return 1
  fi
  header="${header%$'\r'}"
  header_lc="${header,,}"

  if [[ "$header_lc" =~ ^content-length:[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
    len="${BASH_REMATCH[1]}"

    # Consume remaining headers up to the blank separator line
    while IFS= read -r hdr; do
      hdr="${hdr%$'\r'}"
      [ -n "$hdr" ] || break
    done

    REPLY=""
    if [ "$len" -gt 0 ]; then
      # Content-Length is a BYTE count; force the C locale so `read -N`
      # counts bytes instead of multi-byte characters (a UTF-8 locale would
      # under-consume the body and desync the stream on non-ASCII content).
      LC_ALL=C IFS= read -r -N "$len" REPLY || true
    fi
    return 0
  fi

  if [ -z "$header" ]; then
    _mcp_read_message || return 1
    return 0
  fi

  REPLY="$header"
  return 0
}

# mcp_serve — main loop: read JSON-RPC messages from stdin, respond on stdout
mcp_serve() {
  local strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

  # Source tool handlers
  source "$strut_home/lib/mcp/tools.sh"

  while _mcp_read_message; do
    local line="$REPLY"

    local method id params
    method=$(printf '%s' "$line" | jq -r '.method // empty' 2>/dev/null) || continue
    id=$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)
    params=$(printf '%s' "$line" | jq -c '.params // {}' 2>/dev/null)

    case "$method" in
      initialize)
        _mcp_respond "$id" "$(_mcp_initialize)"
        ;;
      notifications/initialized)
        # Client acknowledgement — no response needed
        ;;
      tools/list)
        _mcp_respond "$id" "$(_mcp_tools_list)"
        ;;
      tools/call)
        local tool_name tool_args
        tool_name=$(printf '%s' "$params" | jq -r '.name // empty')
        tool_args=$(printf '%s' "$params" | jq -c '.arguments // {}')
        _mcp_respond "$id" "$(_mcp_tools_call "$tool_name" "$tool_args")"
        ;;
      ping)
        _mcp_respond "$id" '{}'
        ;;
      *)
        _mcp_error "$id" -32601 "Method not found: $method"
        ;;
    esac
  done
}

# _mcp_write — write a single JSON-RPC message to stdout.
# MCP stdio transport spec: one message per line, newline-delimited, no
# embedded newlines, no header layer. Compact the complete envelope here so
# multi-line handler results cannot split one response into multiple records.
_mcp_write() {
  local body="$1"
  printf '%s' "$body" | jq -c .
}

# _mcp_respond <id> <result_json>
_mcp_respond() {
  local id="$1"
  local result="$2"
  local body
  body=$(printf '{"jsonrpc":"2.0","id":%s,"result":%s}' \
    "$(jq -n --arg id "$id" 'if ($id | test("^[0-9]+$")) then ($id | tonumber) else $id end')" \
    "$result")
  _mcp_write "$body"
}

# _mcp_error <id> <code> <message>
_mcp_error() {
  local id="$1"
  local code="$2"
  local message="$3"
  local body
  body=$(printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":%s}}' \
    "$(jq -n --arg id "$id" 'if ($id | test("^[0-9]+$")) then ($id | tonumber) else $id end')" \
    "$code" \
    "$(jq -n --arg m "$message" '$m')")
  _mcp_write "$body"
}

# _mcp_initialize — return server capabilities
_mcp_initialize() {
  local strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
  local version="unknown"
  [ -f "$strut_home/VERSION" ] && version=$(tr -d '[:space:]' < "$strut_home/VERSION")
  printf '{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"strut","version":"%s"}}' "$version"
}
