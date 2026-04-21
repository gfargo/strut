#!/usr/bin/env bash
# ==================================================
# lib/cmd_diff.sh — `strut <stack> diff` handler
# ==================================================
# Shows what a deploy would change on the VPS: env vars and compose image
# tags. Complements drift (VPS → local) and deploy --dry-run (commands).

set -euo pipefail

_usage_diff() {
  cat <<'EOF'

Usage: strut <stack> diff [--env <name>] [--json]

Preview what a deploy would change on the VPS. Compares local env and
docker-compose.yml against the versions currently deployed.

Flags:
  --env <name>     Environment (reads .<name>.env)
  --json           Output structured JSON
  --help, -h       Show this help

Exit codes:
  0  No differences detected
  1  Differences detected (useful for CI gates)
  2  Error fetching remote state

Examples:
  strut my-stack diff --env prod
  strut my-stack diff --env prod --json

See also:
  drift      Compares VPS state back to local (detects unexpected drift)
  deploy     --dry-run shows commands; diff shows semantic changes

EOF
}

# cmd_diff — reads CMD_* context vars populated by the flag parser.
#
# Supported CMD_ARGS:
#   --json   Emit machine-readable output
cmd_diff() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local json_mode="${CMD_JSON:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=true; shift ;;
      --help|-h) _usage_diff; return 0 ;;
      *) fail "Unknown flag: $1"; return 1 ;;
    esac
  done

  [ -f "$env_file" ] || { fail "Env file not found: $env_file"; return 2; }
  set -a; source "$env_file"; set +a
  [ -n "${VPS_HOST:-}" ] || { fail "VPS_HOST not set in $env_file — diff requires a remote target"; return 2; }

  local local_compose="$stack_dir/docker-compose.yml"
  [ -f "$local_compose" ] || { fail "Local compose file not found: $local_compose"; return 2; }

  # Resolve remote paths
  local deploy_dir="${VPS_DEPLOY_DIR:-/home/${VPS_USER:-ubuntu}/strut}"
  local remote_env="$deploy_dir/.${env_name:-prod}.env"
  local remote_compose="$deploy_dir/stacks/$stack/docker-compose.yml"

  # Fetch remote content (may be empty if missing)
  local remote_env_content remote_compose_content
  remote_env_content=$(diff_fetch_remote "$remote_env")
  remote_compose_content=$(diff_fetch_remote "$remote_compose")

  local local_env_content local_compose_content
  local_env_content=$(cat "$env_file")
  local_compose_content=$(cat "$local_compose")

  # Produce diffs
  local env_diff image_diff
  env_diff=$(diff_env_content "$local_env_content" "$remote_env_content")
  image_diff=$(diff_images_content "$local_compose_content" "$remote_compose_content")

  local has_changes=0
  [ -n "$env_diff" ] && has_changes=1
  [ -n "$image_diff" ] && has_changes=1

  if [ "$json_mode" = "true" ]; then
    OUTPUT_MODE=json
    out_json_object
      out_json_field "stack" "$stack"
      [ -n "$env_name" ] && out_json_field "env" "$env_name"
      out_json_field "timestamp" "$(date -u +%FT%TZ)"
      out_json_field_raw "has_changes" "$([ "$has_changes" -eq 1 ] && echo true || echo false)"
      _diff_render_section_json "env_vars" "$env_diff"
      _diff_render_section_json "images" "$image_diff"
    out_json_close_object
    out_json_newline
  else
    if [ "$has_changes" -eq 0 ]; then
      ok "No changes — local state matches VPS"
    else
      echo ""
      echo "Pending changes for $stack ($env_name → $VPS_HOST):"
      _diff_render_section_text "Env vars" "$env_diff"
      _diff_render_section_text "Images" "$image_diff"
      echo ""
    fi
  fi

  [ "$has_changes" -eq 1 ] && return 1
  return 0
}
