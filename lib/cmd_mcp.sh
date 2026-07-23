#!/usr/bin/env bash
# ==================================================
# lib/cmd_mcp.sh — MCP server for AI agent integration
# ==================================================
# Exposes strut commands as MCP (Model Context Protocol) tools,
# enabling AI agents to directly inspect and operate stacks.
#
# Provides:
#   cmd_mcp serve   — start MCP server on stdio
#   cmd_mcp install — write MCP config for Kiro/Claude

set -euo pipefail

_usage_mcp() {
  echo ""
  echo "Usage: strut mcp <command>"
  echo ""
  echo "Commands:"
  echo "  serve     Start MCP server on stdio (for IDE integration)"
  echo "  install   Write MCP configuration for your IDE"
  echo ""
  echo "The MCP server exposes strut operations as callable tools,"
  echo "enabling AI agents to deploy, inspect, backup, and debug stacks."
  echo ""
  echo "Requires: npx (preferred, for multi-editor support) or jq (Kiro-only fallback)"
  echo ""
  echo "Supported editors (via agent-add):"
  echo "  Cursor, Claude Code, VS Code Copilot, Windsurf, Kiro,"
  echo "  Gemini CLI, Codex CLI, Augment, Roo Code, and more."
  echo ""
  echo "Options:"
  echo "  --host <editor>   Target a specific editor (e.g. cursor, claude-code, kiro)"
  echo "                    Omit for interactive selection."
  echo ""
  echo "Examples:"
  echo "  strut mcp serve                    # start server (stdio)"
  echo "  strut mcp install                  # interactive editor picker"
  echo "  strut mcp install --host cursor    # install for Cursor"
  echo ""
}

cmd_mcp() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    serve)   _mcp_cmd_serve ;;
    install) _mcp_cmd_install "$@" ;;
    ""|help) _usage_mcp ;;
    *)       _usage_mcp; fail "Unknown mcp subcommand: $subcmd" ;;
  esac
}

_mcp_cmd_serve() {
  command -v jq >/dev/null 2>&1 || fail "strut mcp serve requires 'jq' (apt install jq / brew install jq)"

  # Restore the real client stdin (saved to fd 8 by the entrypoint's MCP
  # stdin protection guard). Without this, mcp_serve would read /dev/null
  # and exit immediately.
  if [ "${_STRUT_MCP_STDIN_SAVED:-false}" = "true" ]; then
    exec 0<&8 8<&-
  fi

  local strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
  source "$strut_home/lib/mcp/protocol.sh"
  mcp_serve
}

_mcp_cmd_install() {
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local project_root="${PROJECT_ROOT:-$PWD}"

  # Use the bare command name if strut is on PATH (portable), otherwise absolute path
  local strut_bin="strut"
  if ! command -v strut >/dev/null 2>&1; then
    strut_bin="$cli_root/strut"
  fi

  # Parse flags
  local host_flag=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --host=*) host_flag="${1#*=}"; shift ;;
      --host)   host_flag="$2"; shift 2 ;;
      --help|-h) _usage_mcp; return 0 ;;
      *) shift ;;
    esac
  done

  local mcp_json
  mcp_json=$(printf '{"strut":{"command":"%s","args":["mcp","serve"]}}' "$strut_bin")

  # Prefer agent-add if npx is available — handles Cursor, Claude Code,
  # VS Code Copilot, Windsurf, Kiro, and 10+ other editors automatically.
  local npx_bin=""
  resolve_npx_bin && npx_bin="$RESOLVED_NPX_BIN"

  if [ -n "$npx_bin" ]; then
    log "Installing strut MCP server via agent-add..."
    local cmd=("$npx_bin" -y agent-add --mcp "$mcp_json")
    [ -n "$host_flag" ] && cmd+=(--host "$host_flag")
    if "${cmd[@]}"; then
      echo ""
      echo "  Read-only tools (auto-approved where supported):"
      echo "    strut_list, strut_status, strut_health, strut_logs,"
      echo "    strut_fleet_status, strut_drift_detect, strut_drift_images,"
      echo "    strut_diff, strut_backup_health, strut_briefing, strut_preflight"
      echo ""
      echo "  Write tools (require approval):"
      echo "    strut_deploy, strut_sync, strut_backup, strut_stop"
      echo ""
      echo "  Restart your IDE to activate."
      return 0
    fi
    warn "agent-add failed; falling back to manual Kiro config..."
  fi

  # Fallback: write Kiro config directly (no npx/Node.js required)
  command -v jq >/dev/null 2>&1 || fail "strut mcp install requires 'jq' or 'npx' (for agent-add)"

  local kiro_config="$project_root/.kiro/settings/mcp.json"
  mkdir -p "$(dirname "$kiro_config")"

  local kiro_json_full
  kiro_json_full=$(jq -n \
    --arg cmd "$strut_bin" \
    '{
      mcpServers: {
        strut: {
          command: $cmd,
          args: ["mcp", "serve"],
          autoApprove: [
            "strut_list",
            "strut_status",
            "strut_health",
            "strut_logs",
            "strut_fleet_status",
            "strut_drift_detect",
            "strut_drift_images",
            "strut_diff",
            "strut_backup_health",
            "strut_briefing",
            "strut_preflight"
          ]
        }
      }
    }')

  if [ -f "$kiro_config" ]; then
    local existing
    existing=$(cat "$kiro_config")
    echo "$existing" | jq --argjson new "$kiro_json_full" '.mcpServers.strut = $new.mcpServers.strut' > "$kiro_config"
    ok "MCP: updated $kiro_config (Kiro only — install npx for multi-editor support)"
  else
    echo "$kiro_json_full" > "$kiro_config"
    ok "MCP: created $kiro_config (Kiro only — install npx for multi-editor support)"
  fi

  echo ""
  echo "  Read-only tools (auto-approved):"
  echo "    strut_list, strut_status, strut_health, strut_logs,"
  echo "    strut_fleet_status, strut_drift_detect, strut_drift_images,"
  echo "    strut_diff, strut_backup_health, strut_briefing, strut_preflight"
  echo ""
  echo "  Write tools (require approval):"
  echo "    strut_deploy, strut_sync, strut_backup, strut_stop"
  echo ""
  echo "  Restart your IDE to activate."
}
