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
  echo "  status [--json]              Show git sync state across all topology hosts"
  echo "  history [--json] [--limit N] Aggregate deploy/release/rollback history across all hosts"
  echo ""
  echo "Examples:"
  echo "  strut fleet status"
  echo "  strut fleet status --json"
  echo "  strut fleet history --limit 20"
  echo ""
}

cmd_fleet() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    status)  _fleet_status "$@" ;;
    history) _fleet_history "$@" ;;
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
        json_entries+=("{\"host\":\"$(json_escape "$host_alias")\",\"status\":\"error\",\"error\":\"failed to parse host spec\"}")
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
        json_entries+=("{\"host\":\"$(json_escape "$host_alias")\",\"status\":\"unreachable\"}")
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
      # FLEET_DIRTY_COUNT is emitted unquoted (it's a count, not a string)
      # so it must be a bare integer — a blank/non-numeric value (e.g. a
      # truncated SSH stream) would otherwise produce invalid JSON like
      # "dirty":,. Default and validate before interpolating.
      local dirty_count="${FLEET_DIRTY_COUNT:-0}"
      [[ "$dirty_count" =~ ^[0-9]+$ ]] || dirty_count=0
      json_entries+=("{\"host\":\"$(json_escape "$host_alias")\",\"status\":\"ok\",\"branch\":\"$(json_escape "$FLEET_BRANCH")\",\"behind\":\"$(json_escape "$FLEET_BEHIND")\",\"ahead\":\"$(json_escape "$FLEET_AHEAD")\",\"dirty\":$dirty_count,\"head_sha\":\"$(json_escape "$FLEET_HEAD_SHA")\"}")
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

# _fleet_history [--json] [--limit N]
#
# Iterates every [stacks] mapping in topology, SSHes into each stack's host,
# and cats its .deploy-history.jsonl. Aggregates everything, sorts by
# timestamp descending (via jq when available — otherwise best-effort file
# order), and prints the most recent N entries across the whole fleet.
_fleet_history() {
  local json_flag=false
  local limit=20
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)  json_flag=true; shift ;;
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  topology_load

  local stacks
  stacks=$(topology_list_stacks)

  if [ -z "$stacks" ]; then
    if $json_flag; then
      echo '{"entries":[],"error":"No stacks mapped in [stacks] section of strut.conf"}'
    else
      warn "No stacks mapped in [stacks] section of strut.conf"
    fi
    return 0
  fi

  local raw_entries=""
  local stack host_alias host_spec deploy_dir ssh_opts entry_lines

  while IFS= read -r stack; do
    [ -n "$stack" ] || continue
    host_alias="${_TOPO_STACK_HOST[$stack]:-}"
    [ -n "$host_alias" ] || continue

    host_spec="${_TOPO_HOSTS[$host_alias]:-}"
    [ -n "$host_spec" ] || continue
    parse_host_spec "$host_spec" || continue

    deploy_dir="${CONN_DEPLOY_DIR:-/home/${CONN_USER}/strut}"
    ssh_opts=$(build_ssh_opts -p "${CONN_PORT:-22}" -k "${CONN_KEY:-}" --batch)

    # shellcheck disable=SC2029
    entry_lines=$(ssh $ssh_opts "$CONN_USER@$CONN_HOST" "tail -n $limit '$deploy_dir/stacks/$stack/.deploy-history.jsonl' 2>/dev/null" 2>/dev/null) || continue
    [ -n "$entry_lines" ] || continue

    # Tag each entry with the host alias it came from — history_record
    # itself doesn't know its topology alias, only the aggregator does.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if command -v jq &>/dev/null; then
        line=$(echo "$line" | jq -c --arg host "$host_alias" '. + {host: $host}' 2>/dev/null) || continue
      fi
      raw_entries="${raw_entries}${line}"$'\n'
    done <<< "$entry_lines"
  done <<< "$stacks"

  if [ -z "$raw_entries" ]; then
    if $json_flag; then
      echo '{"entries":[]}'
    else
      echo "No history recorded across the fleet yet."
    fi
    return 0
  fi

  local sorted_entries
  if command -v jq &>/dev/null; then
    sorted_entries=$(echo "$raw_entries" | jq -c -s 'sort_by(.timestamp) | reverse | .[]' 2>/dev/null | head -n "$limit")
  else
    sorted_entries=$(echo "$raw_entries" | sed '1!G;h;$!d' | head -n "$limit")
  fi

  if $json_flag; then
    printf '['
    local first=true line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if [ "$first" = "true" ]; then first=false; else printf ','; fi
      printf '%s' "$line"
    done <<< "$sorted_entries"
    printf ']\n'
    return 0
  fi

  if command -v jq &>/dev/null; then
    printf "  %-21s %-10s %-9s %-9s %-8s %s\n" "TIMESTAMP" "HOST" "ACTION" "OUTCOME" "USER" "ENV"
    local line ts host action outcome user env
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      ts=$(echo "$line" | jq -r '.timestamp // "?"')
      host=$(echo "$line" | jq -r '.host // "?"')
      action=$(echo "$line" | jq -r '.action // "?"')
      outcome=$(echo "$line" | jq -r '.outcome // "?"')
      user=$(echo "$line" | jq -r '.user // "?"')
      env=$(echo "$line" | jq -r '.env // "-"')
      printf "  %-21s %-10s %-9s %-9s %-8s %s\n" "$ts" "$host" "$action" "$outcome" "$user" "$env"
    done <<< "$sorted_entries"
  else
    echo "$sorted_entries"
  fi
}
