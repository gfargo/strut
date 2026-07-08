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
      local stack; stack=$(printf '%s' "$args" | jq -r '.stack')
      output=$("$strut_bin" "$stack" status --env "${env:-prod}" --json 2>&1) || rc=$?
      ;;
    strut_health)
      local stack env
      stack=$(printf '%s' "$args" | jq -r '.stack')
      env=$(printf '%s' "$args" | jq -r '.env // "prod"')
      output=$("$strut_bin" "$stack" health --env "$env" --json 2>&1) || rc=$?
      ;;
    strut_logs)
      local stack service lines
      stack=$(printf '%s' "$args" | jq -r '.stack')
      service=$(printf '%s' "$args" | jq -r '.service // ""')
      lines=$(printf '%s' "$args" | jq -r '.lines // 50')
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
      local stack; stack=$(printf '%s' "$args" | jq -r '.stack')
      output=$("$strut_bin" "$stack" drift detect --env prod 2>&1) || rc=$?
      ;;
    strut_drift_images)
      local stack; stack=$(printf '%s' "$args" | jq -r '.stack')
      output=$("$strut_bin" "$stack" drift images --json --env prod 2>&1) || rc=$?
      ;;
    strut_diff)
      local stack; stack=$(printf '%s' "$args" | jq -r '.stack')
      output=$("$strut_bin" "$stack" diff --json --env prod 2>&1) || rc=$?
      ;;
    strut_backup_health)
      local stack; stack=$(printf '%s' "$args" | jq -r '.stack')
      output=$("$strut_bin" "$stack" backup health --env prod --json 2>&1) || rc=$?
      ;;
    strut_deploy)
      local stack env
      stack=$(printf '%s' "$args" | jq -r '.stack')
      env=$(printf '%s' "$args" | jq -r '.env // "prod"')
      output=$("$strut_bin" "$stack" release --env "$env" 2>&1) || rc=$?
      ;;
    strut_sync)
      local host; host=$(printf '%s' "$args" | jq -r '.host')
      output=$("$strut_bin" sync "$host" 2>&1) || rc=$?
      ;;
    strut_backup)
      local stack target
      stack=$(printf '%s' "$args" | jq -r '.stack')
      target=$(printf '%s' "$args" | jq -r '.target // "all"')
      output=$("$strut_bin" "$stack" backup "$target" --env prod 2>&1) || rc=$?
      ;;
    strut_stop)
      local stack; stack=$(printf '%s' "$args" | jq -r '.stack')
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
