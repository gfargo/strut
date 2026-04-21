#!/usr/bin/env bash
# ==================================================
# lib/cmd_group.sh — `strut group <name> <command>` dispatcher
# ==================================================
# Iterates the stacks in a group and runs a strut command against each.
# The engine is a thin shell-out to `$0 <stack> <cmd> [args]` — re-using
# the main entrypoint rather than calling cmd_* inline, so one stack's
# state cannot corrupt the next. Slower, but predictable.

set -euo pipefail

_usage_group() {
  cat <<'EOF'

Usage:
  strut group list                              List all groups
  strut group show <name>                       Show stacks in a group
  strut group add <name> <stack>                Add a stack to a group
  strut group remove <name> <stack>             Remove a stack from a group
  strut group <name> <command> [--env <name>] [--stop-on-error] [options]
                                                Run command for all stacks in group

Flags (for group execution):
  --stop-on-error   Halt on the first failing stack (default: continue)
  --json            Summary as JSON (text summary otherwise)
  --help, -h        Show this help

Groups are defined in groups.conf at the project root. INI-style:

    [vps-1]
    knowledge-graph
    api-service

Exit codes:
  0   All stacks succeeded
  1   One or more stacks failed

Examples:
  strut group vps-1 deploy --env prod
  strut group postgres-stacks backup postgres
  strut group list
  strut group show vps-1
  strut group add vps-1 new-stack

EOF
}

_group_stack_exists() {
  # A stack is "real" if stacks/<name>/ exists under either the project
  # or the strut home (scaffold fallback). Missing stacks are warned, not
  # fatal, per acceptance criteria.
  local stack="$1"
  [ -d "${PROJECT_ROOT:-}/stacks/$stack" ] || [ -d "$CLI_ROOT/stacks/$stack" ]
}

_group_list() {
  local groups
  groups=$(groups_list)
  if [ -z "$groups" ]; then
    warn "No groups defined. Create groups.conf at the project root."
    return 0
  fi
  local g members count
  while IFS= read -r g; do
    members=$(groups_members "$g")
    # awk's count (vs `grep -c`) so an empty group doesn't exit 1 under set -e
    count=$(printf '%s\n' "$members" | awk 'NF { n++ } END { print n+0 }')
    printf '  %-30s %d stacks\n' "$g" "$count"
  done <<< "$groups"
}

_group_show() {
  local group="$1"
  if ! groups_exists "$group"; then
    fail "Unknown group: $group"
  fi
  echo "Group: $group"
  local members
  members=$(groups_members "$group")
  if [ -z "$members" ]; then
    echo "  (empty)"
    return 0
  fi
  local stack marker
  while IFS= read -r stack; do
    if _group_stack_exists "$stack"; then
      marker="✓"
    else
      marker="✗ (missing)"
    fi
    printf '  %s %s\n' "$marker" "$stack"
  done <<< "$members"
}

_group_add() {
  local group="$1" stack="$2"
  [ -z "$group" ] && fail "Missing group name"
  [ -z "$stack" ] && fail "Missing stack name"
  groups_add "$group" "$stack"
  ok "Added '$stack' to group '$group'"
}

_group_remove() {
  local group="$1" stack="$2"
  [ -z "$group" ] && fail "Missing group name"
  [ -z "$stack" ] && fail "Missing stack name"
  groups_remove "$group" "$stack"
  ok "Removed '$stack' from group '$group'"
}

# _group_dispatch <group> <command> [args...]
#
# Iterates stacks in the group and invokes `$0 <stack> <command> [args]`
# sequentially. Collects per-stack exit codes. Prints a summary at the
# end and returns 0 only if every stack succeeded.
_group_dispatch() {
  local group="$1"; shift
  local cmd="$1"; shift
  local stop_on_error=false
  local json_mode=false
  local -a passthrough=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stop-on-error) stop_on_error=true; shift ;;
      --json) json_mode=true; passthrough+=("$1"); shift ;;
      *) passthrough+=("$1"); shift ;;
    esac
  done

  if ! groups_exists "$group"; then
    fail "Unknown group: $group"
  fi

  local members
  members=$(groups_members "$group")
  if [ -z "$members" ]; then
    warn "Group '$group' has no stacks"
    return 0
  fi

  local total=0 passed=0 failed=0
  local -a failed_stacks=()
  local stack

  if [ "$json_mode" != "true" ]; then
    echo ""
    echo "▶ Running '$cmd' for group '$group':"
    echo ""
  fi

  while IFS= read -r stack; do
    [ -z "$stack" ] && continue
    total=$((total + 1))

    if ! _group_stack_exists "$stack"; then
      warn "  skip: $stack (no stacks/$stack directory found)"
      continue
    fi

    if [ "$json_mode" != "true" ]; then
      echo "── $stack ───────────────────────────────"
    fi

    # Shell out to the main strut entrypoint. Using "$0" re-uses the
    # exact binary the user invoked, including its resolved Strut_Home.
    if "$0" "$stack" "$cmd" "${passthrough[@]+"${passthrough[@]}"}"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      failed_stacks+=("$stack")
      if [ "$stop_on_error" = "true" ]; then
        break
      fi
    fi
  done <<< "$members"

  if [ "$json_mode" = "true" ]; then
    OUTPUT_MODE=json
    out_json_object
      out_json_field "group" "$group"
      out_json_field "command" "$cmd"
      out_json_field_raw "total" "$total"
      out_json_field_raw "passed" "$passed"
      out_json_field_raw "failed" "$failed"
      out_json_array "failed_stacks"
      local s
      for s in "${failed_stacks[@]+"${failed_stacks[@]}"}"; do
        out_json_string "$s"
      done
      out_json_close_array
    out_json_close_object
    out_json_newline
  else
    echo ""
    if [ "$failed" -eq 0 ]; then
      ok "$passed/$total stacks succeeded"
    else
      error "$failed/$total stacks failed: ${failed_stacks[*]}"
    fi
  fi

  [ "$failed" -eq 0 ]
}

# cmd_group — entry point invoked from strut entrypoint.
# Usage patterns:
#   cmd_group list
#   cmd_group show <group>
#   cmd_group add <group> <stack>
#   cmd_group remove <group> <stack>
#   cmd_group <group> <command> [args...]
cmd_group() {
  local first="${1:-}"
  shift || true

  case "$first" in
    ""|--help|-h)  _usage_group ;;
    list)          _group_list ;;
    show)          _group_show "${1:-}" ;;
    add)           _group_add "${1:-}" "${2:-}" ;;
    remove)        _group_remove "${1:-}" "${2:-}" ;;
    *)
      local cmd="${1:-}"
      shift || true
      [ -z "$cmd" ] && { _usage_group; fail "Missing command for group '$first'"; }
      _group_dispatch "$first" "$cmd" "$@"
      ;;
  esac
}
