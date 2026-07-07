#!/usr/bin/env bash
# ==================================================
# lib/cmd_fleet.sh — Fleet-wide status across topology [hosts]
# ==================================================
# Requires: lib/utils.sh, lib/fleet.sh, lib/topology.sh, lib/connection.sh
#
# Provides:
#   cmd_fleet status [--json]

set -euo pipefail

_usage_fleet() {
  echo ""
  echo "Usage: strut fleet <command> [options]"
  echo ""
  echo "Commands:"
  echo "  status [--json]    Show git sync state across all topology hosts"
  echo ""
  echo "Examples:"
  echo "  strut fleet status"
  echo "  strut fleet status --json"
  echo ""
}

cmd_fleet() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    status) _fleet_status "$@" ;;
    ""|help) _usage_fleet ;;
    *) _usage_fleet; fail "Unknown fleet subcommand: $subcmd" ;;
  esac
}

# _fleet_status [--json]
#
# Iterates all [hosts] from topology, runs fleet_git_status on each,
# and renders a table (or JSON) showing behind/ahead/dirty per host.
_fleet_status() {
  local json_flag=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_flag=true; shift ;;
      *) shift ;;
    esac
  done

  topology_load

  local hosts
  hosts=$(topology_list_hosts)

  if [ -z "$hosts" ]; then
    if $json_flag; then
      echo '{"hosts":[],"error":"No hosts defined in [hosts] section of strut.conf"}'
    else
      warn "No hosts defined in [hosts] section of strut.conf"
    fi
    return 0
  fi

  local branch="${DEFAULT_BRANCH:-main}"
  local gh_pat="${GH_PAT:-}"
  local json_entries=()
  local table_rows=()

  if ! $json_flag; then
    echo ""
    printf "  %-12s %-8s %-6s %-6s %-5s %s\n" "HOST" "BRANCH" "BEHIND" "AHEAD" "DIRTY" "HEAD"
    printf "  %-12s %-8s %-6s %-6s %-5s %s\n" "────" "──────" "──────" "─────" "─────" "────"
  fi

  while IFS= read -r host_alias; do
    [ -n "$host_alias" ] || continue

    # Resolve connection for this host
    local host_spec="${_TOPO_HOSTS[$host_alias]:-}"
    [ -n "$host_spec" ] || continue

    if ! parse_host_spec "$host_spec"; then
      if $json_flag; then
        json_entries+=("{\"host\":\"$host_alias\",\"status\":\"error\",\"error\":\"failed to parse host spec\"}")
      else
        printf "  %-12s %-8s %-6s %-6s %-5s %s\n" "$host_alias" "—" "—" "—" "—" "parse error"
      fi
      continue
    fi

    local deploy_dir="${CONN_DEPLOY_DIR:-/home/${CONN_USER}/strut}"

    # Run fleet_git_status (with timeout awareness — SSH might hang)
    local status_output=""
    status_output=$(fleet_git_status "$CONN_USER" "$CONN_HOST" "$CONN_PORT" "$CONN_KEY" "$deploy_dir" "$branch" "$gh_pat" 2>/dev/null) || true

    if [ -z "$status_output" ]; then
      if $json_flag; then
        json_entries+=("{\"host\":\"$host_alias\",\"status\":\"unreachable\"}")
      else
        printf "  %-12s %-8s %-6s %-6s %-5s %s\n" "$host_alias" "—" "—" "—" "—" "unreachable"
      fi
      continue
    fi

    # Parse the KV output
    local FLEET_HEAD_SHA="" FLEET_BRANCH="" FLEET_BEHIND="" FLEET_AHEAD="" FLEET_DIRTY_COUNT=""
    eval "$(echo "$status_output" | fleet_git_status_parse)"

    local short_sha="${FLEET_HEAD_SHA:0:7}"
    [ "$FLEET_HEAD_SHA" = "missing" ] && short_sha="missing"
    [ "$FLEET_HEAD_SHA" = "unknown" ] && short_sha="unknown"

    if $json_flag; then
      json_entries+=("{\"host\":\"$host_alias\",\"status\":\"ok\",\"branch\":\"$FLEET_BRANCH\",\"behind\":\"$FLEET_BEHIND\",\"ahead\":\"$FLEET_AHEAD\",\"dirty\":$FLEET_DIRTY_COUNT,\"head_sha\":\"$FLEET_HEAD_SHA\"}")
    else
      # Color-code behind count
      local behind_str="$FLEET_BEHIND"
      if [ "$FLEET_BEHIND" != "?" ] && [ "$FLEET_BEHIND" -gt 0 ] 2>/dev/null; then
        behind_str="${YELLOW}${FLEET_BEHIND}${NC}"
      fi
      local dirty_str="$FLEET_DIRTY_COUNT"
      if [ "$FLEET_DIRTY_COUNT" -gt 0 ] 2>/dev/null; then
        dirty_str="${RED}${FLEET_DIRTY_COUNT}${NC}"
      fi
      printf "  %-12s %-8s %-6b %-6s %-5b %s\n" "$host_alias" "$FLEET_BRANCH" "$behind_str" "$FLEET_AHEAD" "$dirty_str" "$short_sha"
    fi
  done <<< "$hosts"

  if $json_flag; then
    local joined
    joined=$(printf '%s,' "${json_entries[@]}")
    joined="${joined%,}"  # strip trailing comma
    echo "{\"hosts\":[$joined],\"branch\":\"$branch\"}"
  else
    echo ""
  fi
}
