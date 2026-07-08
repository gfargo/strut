# MCP Server

strut includes a built-in [Model Context Protocol](https://modelcontextprotocol.io/) server that exposes stack operations as callable tools for AI agents.

## Quick Start

```bash
strut mcp install    # writes .kiro/settings/mcp.json
# Restart your IDE — strut tools appear in the agent's tool list
```

## How It Works

The MCP server runs as a subprocess (stdio transport) managed by your IDE. When activated:

1. IDE starts `strut mcp serve` as a background process
2. Agent sees 13 strut tools in its tool list
3. When you ask "check my fleet status" or "deploy my-app", the agent calls the appropriate tool directly
4. Results flow back to the agent as structured text

No network ports, no authentication — the server runs locally with your user's permissions.

## Available Tools

### Read-Only (auto-approved)

These tools are safe to run without confirmation:

| Tool | Description |
|------|-------------|
| `strut_list` | List all stacks in the project |
| `strut_status` | Container status for a stack |
| `strut_health` | Health check results (JSON) |
| `strut_logs` | Recent logs for a service |
| `strut_fleet_status` | Git sync state across all hosts |
| `strut_drift_detect` | Configuration drift detection |
| `strut_drift_images` | Stale image digest detection |
| `strut_diff` | Pending changes vs VPS |
| `strut_backup_health` | Backup health scores |

### Write (require approval)

These tools modify state and prompt for confirmation:

| Tool | Description |
|------|-------------|
| `strut_deploy` | Deploy/release a stack to VPS |
| `strut_sync` | Bring a host in sync with origin |
| `strut_backup` | Create a database backup |
| `strut_stop` | Stop containers for a stack |

## Installation

### Kiro IDE

```bash
strut mcp install
```

This writes `.kiro/settings/mcp.json`:

```json
{
  "mcpServers": {
    "strut": {
      "command": "/path/to/strut",
      "args": ["mcp", "serve"],
      "autoApprove": [
        "strut_list", "strut_status", "strut_health",
        "strut_logs", "strut_fleet_status", "strut_drift_detect",
        "strut_drift_images", "strut_diff", "strut_backup_health"
      ]
    }
  }
}
```

### Claude Code

Add to your MCP config (`.claude/settings.json` or `~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "strut": {
      "command": "/path/to/strut",
      "args": ["mcp", "serve"]
    }
  }
}
```

### Other IDEs

Any MCP-compatible tool can use strut's server. The transport is stdio (stdin/stdout JSON-RPC). Configure:
- Command: `strut mcp serve` (or full path to the strut binary)
- Transport: stdio

## Requirements

- `jq` must be installed (`brew install jq` / `apt install jq`)
- strut project must be initialized (`strut.conf` exists)
- For remote operations: env file with VPS connection info

## Example Conversations

**"Is my fleet in sync?"**
→ Agent calls `strut_fleet_status` → shows behind/ahead per host

**"Check the health of my-app"**
→ Agent calls `strut_health` with `{"stack": "my-app"}` → returns health check JSON

**"Deploy my-app to production"**
→ Agent calls `strut_deploy` with `{"stack": "my-app", "env": "prod"}` → prompts for approval → runs release

**"Show me the last 100 lines of nginx logs"**
→ Agent calls `strut_logs` with `{"stack": "my-app", "service": "nginx", "lines": 100}`

**"Are any images stale?"**
→ Agent calls `strut_drift_images` with `{"stack": "my-app"}` → reports digest drift

## Architecture

```
IDE (Kiro, Claude, Cursor, etc.)
  ↓ JSON-RPC over stdio
strut mcp serve
  ↓ invokes
strut CLI commands (existing infrastructure)
  ↓ SSH
VPS
```

The MCP server is a thin JSON-RPC adapter. All actual work is done by existing strut commands — the same code paths used by manual CLI invocations.

## Relationship to Agent Skills

| Layer | Purpose | How it works |
|-------|---------|-------------|
| **Agent Skill** | Passive knowledge | Teaches the agent strut conventions and procedures |
| **MCP Server** | Active capability | Lets the agent execute strut commands directly |

Together: the agent knows *what* to do (skill) and *can* do it (MCP server). Install both for the best experience.

## Troubleshooting

### "jq: command not found"

Install jq: `brew install jq` (macOS) or `apt install jq` (Linux).

### Tools don't appear in IDE

1. Check config path is correct for your IDE
2. Verify `strut mcp serve` runs without error: `echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | strut mcp serve`
3. Restart the IDE after config changes

### Tool calls return errors

Most errors come from missing env files or VPS connection info. The error message from the tool will indicate what's missing (usually `VPS_HOST not set`).

## Related

- [Agent Skills](https://github.com/gfargo/strut/wiki/CLI-Reference) — passive AI context
- [Fleet Status](https://github.com/gfargo/strut/wiki/Fleet-Status) — what `strut_fleet_status` returns
- [Push-to-Deploy](https://github.com/gfargo/strut/wiki/Push-to-Deploy) — auto-deploy (complementary)
