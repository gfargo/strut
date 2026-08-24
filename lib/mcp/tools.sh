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
  {"name":"strut_briefing","description":"One-call operational situation report: aggregates health, config drift, image staleness, pending diff, and backup health into an overall posture plus prioritized actions","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"env":{"type":"string","description":"Environment name (default: prod)"}},"required":["stack"]}},
  {"name":"strut_preflight","description":"Deploy go/no-go verdict (GO/CAUTION/NO-GO): fuses pending diff, config drift, current health, and backup freshness into a release-safety decision with reasons","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"env":{"type":"string","description":"Environment name (default: prod)"}},"required":["stack"]}},
  {"name":"strut_deploy","description":"Deploy a stack to its VPS. Without confirm:true, runs in dry-run mode showing the execution plan. Pass confirm:true to execute the full pipeline: sync repo, run migrations, pull images, restart services, health-check, and auto-roll-back if unhealthy. Fails if the stack does not resolve to a remote host.","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"env":{"type":"string","description":"Environment name (default: prod)"},"confirm":{"type":"boolean","description":"Set to true to actually execute the deploy. Omit or false for a dry-run preview."}},"required":["stack"]}},
  {"name":"strut_sync","description":"Bring a host checkout in sync with origin","inputSchema":{"type":"object","properties":{"host":{"type":"string","description":"Host alias from topology"}},"required":["host"]}},
  {"name":"strut_backup","description":"Create a backup for a stack","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"target":{"type":"string","description":"Backup target (postgres, neo4j, mysql, sqlite, all). Default: all"}},"required":["stack"]}},
  {"name":"strut_stop","description":"Stop containers for a stack. Without confirm:true, runs in dry-run mode showing what would be stopped. Pass confirm:true to actually stop and remove containers.","inputSchema":{"type":"object","properties":{"stack":{"type":"string","description":"Stack name"},"confirm":{"type":"boolean","description":"Set to true to actually stop the stack. Omit or false for a dry-run preview."}},"required":["stack"]}}
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

# _mcp_tool_is_informational <tool>
#
# True for read-only tools that use non-zero exit codes to signal
# "attention needed" (unhealthy, has-changes, NO-GO) rather than failure,
# and emit structured JSON. For these, a well-formed JSON body on a
# non-zero exit is a successful result — the status/verdict field inside
# already communicates severity — so it must not be double-signalled as an
# MCP error. Genuine failures surface as non-JSON text and stay isError.
_mcp_tool_is_informational() {
  case "$1" in
    strut_health|strut_diff|strut_preflight|strut_briefing|\
    strut_drift_images|strut_backup_health|strut_status|\
    strut_list|strut_fleet_status) return 0 ;;
    *) return 1 ;;
  esac
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

# _mcp_json_tail <text>
#
# `output` is captured with `2>&1`, so any stdout `warn()` lines (this
# repo's convention — see lib/utils.sh:60 — e.g. env_apply_gen_layer's
# "Could not decrypt generated env layer" on a stack using
# env/*.gen.enc.env without an age identity present) land ahead of a
# command's --json body rather than being separated onto stderr. A plain
# `jq -e .` over the whole capture then fails even though the call
# succeeded and produced valid JSON. This scans line-by-line for the first
# `{`/`[`-prefixed line whose suffix (to the end of the text) parses as
# complete JSON, and echoes that suffix. Echoes nothing and returns 1 if no
# such suffix exists.
_mcp_json_tail() {
  local text="$1" line_no candidate
  while IFS= read -r line_no; do
    candidate=$(printf '%s\n' "$text" | tail -n "+$line_no")
    if printf '%s' "$candidate" | jq -e . > /dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done < <(printf '%s\n' "$text" | grep -n '^[{[]' | cut -d: -f1)
  return 1
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
    strut_briefing)
      local stack env
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      env=$(_mcp_arg "$args" env prod) || { _mcp_reject "invalid 'env' argument"; return 0; }
      output=$("$strut_bin" "$stack" briefing --env "$env" --json 2>&1) || rc=$?
      ;;
    strut_preflight)
      local stack env
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      env=$(_mcp_arg "$args" env prod) || { _mcp_reject "invalid 'env' argument"; return 0; }
      output=$("$strut_bin" "$stack" preflight --env "$env" --json 2>&1) || rc=$?
      ;;
    strut_deploy)
      local stack env confirm
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      env=$(_mcp_arg "$args" env prod) || { _mcp_reject "invalid 'env' argument"; return 0; }
      confirm=$(printf '%s' "$args" | jq -r '.confirm // false')
      # Default to dry-run unless explicitly confirmed (strut#516)
      if [ "$confirm" = "true" ]; then
        output=$("$strut_bin" "$stack" deploy --require-remote --env "$env" 2>&1) || rc=$?
      else
        output=$("$strut_bin" "$stack" deploy --require-remote --env "$env" --dry-run 2>&1) || rc=$?
      fi
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
      local stack confirm
      stack=$(_mcp_arg "$args" stack) || { _mcp_reject "invalid 'stack' argument"; return 0; }
      confirm=$(printf '%s' "$args" | jq -r '.confirm // false')
      # Default to dry-run unless explicitly confirmed (strut#516)
      if [ "$confirm" = "true" ]; then
        output=$("$strut_bin" "$stack" stop --env prod 2>&1) || rc=$?
      else
        output=$("$strut_bin" "$stack" stop --env prod --dry-run 2>&1) || rc=$?
      fi
      ;;
    *)
      printf '{"content":[{"type":"text","text":"Unknown tool: %s"}],"isError":true}' "$tool"
      return 0
      ;;
  esac

  # Format MCP tool result
  local is_error="false"
  if [ "$rc" -ne 0 ]; then
    local json_tail
    if _mcp_tool_is_informational "$tool" && printf '%s' "$output" | jq -e . > /dev/null 2>&1; then
      is_error="false"   # non-zero exit is informational; JSON body IS the result
    elif _mcp_tool_is_informational "$tool" && json_tail=$(_mcp_json_tail "$output"); then
      # Whole capture wasn't valid JSON, but a trailing suffix is — stdout
      # warn() noise (e.g. env_apply_gen_layer's decrypt-skip warning) ran
      # ahead of the JSON body. Reduce to that suffix so the JSON body IS
      # the result instead of misclassifying on the noise.
      output="$json_tail"
      is_error="false"
    else
      is_error="true"
    fi
  fi

  local escaped_output
  escaped_output=$(jq -n --arg text "$output" '$text')
  if [ "$is_error" = "false" ]; then
    printf '{"content":[{"type":"text","text":%s}]}' "$escaped_output"
  else
    printf '{"content":[{"type":"text","text":%s}],"isError":true}' "$escaped_output"
  fi
}
