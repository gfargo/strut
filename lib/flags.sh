#!/usr/bin/env bash
# ==================================================
# lib/flags.sh — Shared flag parsing
# ==================================================
# Centralizes parsing of the universal flags every command accepts:
#   --env <name> | --env=<name>
#   --services <profile> | --services=<profile>
#   --json
#   --dry-run
#   --help | -h
#
# Handler-specific flags are left in FLAGS_POSITIONAL for the caller
# to parse. Supports both "--env name" and "--env=name" forms.

set -euo pipefail

# parse_common_flags "$@"
# Populates globals:
#   FLAGS_ENV_NAME   — value of --env (empty if not set)
#   FLAGS_SERVICES   — value of --services (empty if not set)
#   FLAGS_JSON       — "--json" if flag present, empty otherwise
#   FLAGS_DRY_RUN    — "true" if --dry-run present, "" otherwise
#   FLAGS_HELP       — "true" if --help/-h present, "" otherwise
#   FLAGS_POSITIONAL — array of remaining args (non-common flags and positionals)
parse_common_flags() {
  FLAGS_ENV_NAME=""
  FLAGS_SERVICES=""
  FLAGS_JSON=""
  FLAGS_DRY_RUN=""
  FLAGS_HELP=""
  FLAGS_POSITIONAL=()

  while [[ $# -gt 0 ]]; do
    case $1 in
      --env=*)       FLAGS_ENV_NAME="${1#*=}"; shift ;;
      --env)         FLAGS_ENV_NAME="${2:-}"; shift 2 ;;
      --services=*)  FLAGS_SERVICES="${1#*=}"; shift ;;
      --services)    FLAGS_SERVICES="${2:-}"; shift 2 ;;
      --json)        FLAGS_JSON="--json"; shift ;;
      --dry-run)     FLAGS_DRY_RUN="true"; shift ;;
      --help|-h)     FLAGS_HELP="true"; shift ;;
      *)             FLAGS_POSITIONAL+=("$1"); shift ;;
    esac
  done
}

# flags_has_help "$@"
# Returns 0 if --help or -h appears anywhere in the arg list.
flags_has_help() {
  for arg in "$@"; do
    [[ "$arg" == "--help" || "$arg" == "-h" ]] && return 0
  done
  return 1
}
