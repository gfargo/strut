#!/usr/bin/env bash
# ==================================================
# lib/mcp/protocol.sh — MCP JSON-RPC protocol handler (stdio)
# ==================================================
# Reads JSON-RPC messages from stdin, dispatches to handlers, writes responses
# to stdout. Implements the Model Context Protocol for AI agent integration.

set -euo pipefail

# mcp_serve — main loop: read JSON-RPC messages from stdin, respond on stdout
mcp_serve() {
  local strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

  # Source tool handlers
  source "$strut_home/lib/mcp/tools.sh"

  while IFS= read -r line; do
    [ -n "$line" ] || continue

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

# _mcp_respond <id> <result_json>
_mcp_respond() {
  local id="$1"
  local result="$2"
  printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' \
    "$(jq -n --arg id "$id" 'if ($id | test("^[0-9]+$")) then ($id | tonumber) else $id end')" \
    "$result"
}

# _mcp_error <id> <code> <message>
_mcp_error() {
  local id="$1"
  local code="$2"
  local message="$3"
  printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":%s}}\n' \
    "$(jq -n --arg id "$id" 'if ($id | test("^[0-9]+$")) then ($id | tonumber) else $id end')" \
    "$code" \
    "$(jq -n --arg m "$message" '$m')"
}

# _mcp_initialize — return server capabilities
_mcp_initialize() {
  cat << 'EOF'
{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"strut","version":"0.32.0"}}
EOF
}
