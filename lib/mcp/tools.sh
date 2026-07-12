#!/usr/bin/env bash
# ==================================================
# lib/mcp/tools.sh — MCP tool definitions and dispatch
# ==================================================

set -euo pipefail

# _mcp_tools_list — return the list of available tools
_mcp_tools_list() {
  cat << 'EOF'
{"tools":[
  {"name":"strut_list","description":"List all stacks in the project","inputSchema":{"type":"object","properties":{}}},
  {"name":"strut_status","description":"Get container status for a stack","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"}},"required":["stack"]}},
  {"name":"strut_health","description":"Run health checks for a stack","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"env":{"type":"string","description":"Environment name (default: prod)"}},"required":["stack"]}},
  {"name":"strut_logs","description":"Get recent logs for a service in a stack","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"service":{"type":"string","description":"Service name"},"lines":{"type":"number","description":"Number of lines (default: 50)"}},"required":["stack"]}},
  {"name":"strut_fleet_status","description":"Show git sync state across all topology hosts","inputSchema":{"type":"object","properties":{}}},
  {"name":"strut_drift_detect","description":"Detect configuration drift for a stack","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"}},"required":["stack"]}},
  {"name":"strut_drift_images","description":"Check for stale container image digests","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"}},"required":["stack"]}},
  {"name":"strut_diff","description":"Preview pending changes vs VPS for a stack","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"}},"required":["stack"]}},
  {"name":"strut_backup_health","description":"Show backup health scores for a stack","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"}},"required":["stack"]}},
  {"name":"strut_deploy","description":"Deploy/release a stack to VPS (requires approval)","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"env":{"type":"string","description":"Environment name (default: prod)"}},"required":["stack"]}},
  {"name":"strut_sync","description":"Bring a host checkout in sync with origin","inputSchema":{"type":"object","properties":{"host":{"type":"string","description":"Host alias from topology"}},"required":["host"]}},
  {"name":"strut_backup","description":"Create a backup for a stack","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"target":{"type":"string","description":"Backup target (postgres, neo4j, mysql, sqlite, all). Default: all"}},"required":["stack"]}},
  {"name":"strut_stop","description":"Stop containers for a stack (requires approval)","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"}},"required":["stack"]}}
]}
EOF
}

# _mcp_reject <message>
#
# Emits an MCP isError result for a rejected tool call. Callers `return 0`
# right after so _mcp_tools_call exits cleanly without invoking strut.
_mcp_reject() {
  local msg="$1" escaped
  escaped=$(jq -n --arg text "$msg" '$text')
  printf '{"content":[{"type":"text","text":%s}],"isError":true}' "$escaped"
}

# _mcp_arg <args_json> <field> [default]
#
# Extracts a string field from the MCP tool-call args JSON and validates it
# against strut's identifier charset (letters, digits, dot, underscore,
# dash). Tool-call arguments are model-controlled and, for host-scoped
# stacks, ultimately reach a remote shell string built by run_remote_strut
# (lib/utils.sh) — a value containing shell metacharacters could break out
# of that string and execute on the VPS. Echoes the value and returns 0 on
# success; on invalid input, prints nothing and returns 1 so the caller
# rejects the call instead of passing it through.
_mcp_arg() {
  local args="$1" field="$2" default="${3:-}"
  local val
  val=$(printf '%s' "$args" | jq -r --arg f "$field" --arg d "$default" '.[$f] // $d')
  [[ "$val" =~ ^[A-Za-z0-9_.-]*$ ]] || return 1
  printf '%s' "$val"
}

# _mcp_arg_lines <args_json> [default]
#
# Same contract as _mcp_arg, restricted to non-negative integers (the
# --tail line count for strut_logs).
_mcp_arg_lines() {
  local args="$1" default="${2:-50}"
  local val
  val=$(printf '%s' "$args" | jq -r --arg d "$default" '.lines // $d')
  [[ "$val" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$val"
}

# _mcp_tools_call <tool_name> <args_json>
_mcp_tools_call() {
  local tool="$1"
  local args="$2"
  local strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
  local strut_bin="$strut_home/strut"

  local output rc=0
  case "$tool" in
    strut_list)
      output=$("$strut_bin" list --json 2>&1) || rc=$?
      ;;
    strut_status)
      local stack
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      output=$("$strut_bin" "$stack" status --env prod --json 2>&1) || rc=$?
      ;;
    strut_health)
      local stack env
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      env=$(_mcp_arg "$args" env prod) || { _mcp_reject "invalid 'env' argument"; return 0; }
      output=$("$strut_bin" "$stack" health --env "$env" --json 2>&1) || rc=$?
      ;;
    strut_logs)
      local stack service lines
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      service=$(_mcp_arg "$args" service "") || { _mcp_reject "invalid 'service' argument"; return 0; }
      lines=$(_mcp_arg_lines "$args") || { _mcp_reject "invalid 'lines' argument"; return 0; }
      if [ -n "$service" ]; then
        output=$("$strut_bin" "$stack" logs "$service" --tail "$lines" --env prod 2>&1) || rc=$?
      else
        output=$("$strut_bin" "$stack" logs --tail "$lines" --env prod 2>&1) || rc=$?
      fi
      ;;
    strut_fleet_status)
      output=$("$strut_bin" fleet status --json 2>&1) || rc=$?
      ;;
    strut_drift_detect)
      local stack
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      output=$("$strut_bin" "$stack" drift detect --env prod 2>&1) || rc=$?
      ;;
    strut_drift_images)
      local stack
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      output=$("$strut_bin" "$stack" drift images --json --env prod 2>&1) || rc=$?
      ;;
    strut_diff)
      local stack
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      output=$("$strut_bin" "$stack" diff --json --env prod 2>&1) || rc=$?
      ;;
    strut_backup_health)
      local stack
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      output=$("$strut_bin" "$stack" backup health --env prod --json 2>&1) || rc=$?
      ;;
    strut_deploy)
      local stack env
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      env=$(_mcp_arg "$args" env prod) || { _mcp_reject "invalid 'env' argument"; return 0; }
      output=$("$strut_bin" "$stack" release --env "$env" 2>&1) || rc=$?
      ;;
    strut_sync)
      local host
      host=$(_mcp_arg "$args" host) || { _mcp_reject "invalid 'host' argument"; return 0; }
      output=$("$strut_bin" sync "$host" 2>&1) || rc=$?
      ;;
    strut_backup)
      local stack target
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      target=$(_mcp_arg "$args" target all) || { _mcp_reject "invalid 'target' argument"; return 0; }
      output=$("$strut_bin" "$stack" backup "$target" --env prod 2>&1) || rc=$?
      ;;
    strut_stop)
      local stack
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      output=$("$strut_bin" "$stack" stop --env prod 2>&1) || rc=$?
      ;;
    *)
      printf '{"content":[{"type":"text","text":"Unknown tool: %s"}],"isError":true}' "$tool"
      return 0
      ;;
  esac

  # Format MCP tool result
  local escaped_output
  escaped_output=$(jq -n --arg text "$output" '$text')
  if [ "$rc" -eq 0 ]; then
    printf '{"content":[{"type":"text","text":%s}]}' "$escaped_output"
  else
    printf '{"content":[{"type":"text","text":%s}],"isError":true}' "$escaped_output"
  fi
}
