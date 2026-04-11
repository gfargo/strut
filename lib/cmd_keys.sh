#!/usr/bin/env bash
# ==================================================
# cmd_keys.sh — Key management command handler
# ==================================================

set -euo pipefail

_usage_keys() {
  echo ""
  echo "Usage: strut <stack> keys [--env <name>] <subcommand> [options]"
  echo ""
  echo "Key management: SSH keys, API keys, env vars, GitHub secrets."
  echo ""
  echo "Status & Monitoring:"
  echo "  status [--json]                    Show health of all keys"
  echo "  recent [--limit <n>]               Show recent operations"
  echo ""
  echo "Testing:"
  echo "  test                               Test all keys"
  echo "  test:ssh | test:vps | test:env     Test specific key types"
  echo ""
  echo "SSH Keys:"
  echo "  ssh:add <user> [--generate]        Add SSH key"
  echo "  ssh:rotate <user>                  Rotate SSH key"
  echo "  ssh:revoke <user>                  Revoke SSH key"
  echo "  ssh:list [--json]                  List SSH keys"
  echo ""
  echo "API Keys:"
  echo "  api:generate <name>                Generate API key"
  echo "  api:rotate <name>                  Rotate API key"
  echo "  api:list [--json]                  List API keys"
  echo ""
  echo "Environment:"
  echo "  env:rotate [--services <list>]     Rotate env secrets"
  echo "  env:sync                           Sync env vars"
  echo "  env:validate                       Validate env config"
  echo "  env:diff --local <f> --remote      Compare local vs remote env"
  echo ""
  echo "Database:"
  echo "  db:rotate <postgres|neo4j>         Rotate DB credentials"
  echo ""
  echo "GitHub:"
  echo "  github:list --repo <org/repo>      List GitHub secrets"
  echo "  github:sync --repo <r> --from <f>  Sync secrets to GitHub"
  echo ""
  echo "Common flags: --dry-run, --force, --json"
  echo ""
  echo "Examples:"
  echo "  strut my-stack keys status"
  echo "  strut my-stack keys test"
  echo "  strut my-stack keys ssh:add alice --generate --dry-run"
  echo ""
}

# cmd_keys <stack> <env_file> [subcommand] [username] [args...]
cmd_keys() {
  local stack="$1"
  local env_file="$2"
  local subcmd="${3:-}"
  local username="${4:-}"
  shift 4 || shift $#
  keys_command "$stack" "$subcmd" "$username" --env-file "$env_file" "$@"
}
