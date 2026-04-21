#!/usr/bin/env bash
# ==================================================
# cmd_backup.sh — Backup command thin router
# ==================================================
# Forwards CMD_* context variables to backup_command() in lib/backup/cmd.sh.

set -euo pipefail

_usage_backup() {
  echo ""
  echo "Usage: strut <stack> backup [--env <name>] <subcommand> [options]"
  echo ""
  echo "Backup management: create, verify, schedule, and monitor backups."
  echo ""
  echo "Subcommands:"
  echo "  postgres|neo4j|mysql|sqlite|all   Create backup for service(s)"
  echo "  verify <file> [--full]            Verify backup integrity"
  echo "  verify-all                        Verify all backups"
  echo "  list [service]                    List available backups"
  echo "  health                            Check backup health scores"
  echo "  schedule on|off|status|install    Manage backup schedules"
  echo "  retention check|enforce           Manage retention policy"
  echo "  compare <env1> <env2> [service]   Compare backups across environments"
  echo "  compare-labels <env1> <env2>      Compare backup labels"
  echo "  offsite status|sync|list|restore  Offsite backup sync (S3/R2/B2)"
  echo ""
  echo "Examples:"
  echo "  strut my-stack backup postgres --env prod"
  echo "  strut my-stack backup all --env prod"
  echo "  strut my-stack backup verify backups/postgres-20240101.sql"
  echo "  strut my-stack backup list postgres"
  echo "  strut my-stack backup health"
  echo "  strut my-stack backup schedule status"
  echo "  strut my-stack backup retention enforce"
  echo ""
}

# cmd_backup [positional...] (reads CMD_*)
cmd_backup() {
  backup_command \
    "$CMD_STACK" \
    "$CMD_STACK_DIR" \
    "$CMD_ENV_FILE" \
    "$CMD_ENV_NAME" \
    "$CMD_SERVICES" \
    "$CMD_JSON" \
    "$@"
}
