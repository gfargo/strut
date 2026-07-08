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
  echo "Requires: jq"
  echo ""
  echo "Configuration (written by 'strut mcp install'):"
  echo "  Kiro:   .kiro/settings/mcp.json"
  echo "  Claude: .claude/settings.json or ~/.claude/settings.json"
  echo ""
  echo "Examples:"
  echo "  strut mcp serve              # start server (stdio)"
  echo "  strut mcp install            # write IDE config"
  echo ""
}

cmd_mcp() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    serve)   _mcp_cmd_serve ;;
    install) _mcp_cmd_install ;;
    ""|help) _usage_mcp ;;
    *)       _usage_mcp; fail "Unknown mcp subcommand: $subcmd" ;;
  esac
}

_mcp_cmd_serve() {
  command -v jq >/dev/null 2>&1 || fail "strut mcp serve requires 'jq' (apt install jq / brew install jq)"

  local strut_home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
  source "$strut_home/lib/mcp/protocol.sh"
  mcp_serve
}

_mcp_cmd_install() {
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local strut_bin="$cli_root/strut"
  local project_root="${PROJECT_ROOT:-$PWD}"

  # Kiro config
  local kiro_config="$project_root/.kiro/settings/mcp.json"
  mkdir -p "$(dirname "$kiro_config")"

  local kiro_json
  kiro_json=$(jq -n \
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
            "strut_backup_health"
          ]
        }
      }
    }')

  if [ -f "$kiro_config" ]; then
    # Merge into existing config
    local existing
    existing=$(cat "$kiro_config")
    echo "$existing" | jq --argjson new "$kiro_json" '.mcpServers.strut = $new.mcpServers.strut' > "$kiro_config"
    ok "MCP: updated $kiro_config"
  else
    echo "$kiro_json" > "$kiro_config"
    ok "MCP: created $kiro_config"
  fi

  echo ""
  echo "  Read-only tools (auto-approved):"
  echo "    strut_list, strut_status, strut_health, strut_logs,"
  echo "    strut_fleet_status, strut_drift_detect, strut_drift_images,"
  echo "    strut_diff, strut_backup_health"
  echo ""
  echo "  Write tools (require approval):"
  echo "    strut_deploy, strut_sync, strut_backup, strut_stop"
  echo ""
  echo "  Restart your IDE to activate."
}
