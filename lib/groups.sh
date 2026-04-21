#!/usr/bin/env bash
# ==================================================
# lib/groups.sh — Stack group configuration (INI format)
# ==================================================
# groups.conf lives at project root (next to strut.conf) and looks like:
#
#   [vps-1]
#   knowledge-graph
#   api-service
#
#   [postgres-stacks]
#   knowledge-graph
#   twenty
#
# Stacks can belong to multiple groups. Groups are label-only — no
# ordering or dependency semantics (those could come later).
#
# Parser is pure awk for portability: no yq, no jq. All functions return
# via stdout; non-zero exit = not found / invalid.

set -euo pipefail

# groups_config_path
#   Absolute path to groups.conf for the current project.
#   Callers can override via $STRUT_GROUPS_CONF for tests.
groups_config_path() {
  if [ -n "${STRUT_GROUPS_CONF:-}" ]; then
    echo "$STRUT_GROUPS_CONF"
    return 0
  fi
  local root="${PROJECT_ROOT:-$(pwd)}"
  echo "$root/groups.conf"
}

# groups_ensure_config
#   Creates an empty groups.conf (with a header) if one doesn't exist.
groups_ensure_config() {
  local path
  path=$(groups_config_path)
  if [ ! -f "$path" ]; then
    cat > "$path" <<'EOF'
# groups.conf — stack groups for `strut group <name> <command>`
#
# INI-style. Group names in [brackets]; one stack per line underneath.
# Comments start with #. A stack may appear in multiple groups.

EOF
  fi
}

# groups_list
#   Emits all group names, one per line, in file order.
groups_list() {
  local path
  path=$(groups_config_path)
  [ -f "$path" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      name = $0
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\][[:space:]]*$/, "", name)
      print name
    }
  ' "$path"
}

# groups_members <group>
#   Emits stack names in the group, one per line.
#   Exit 0 even if the group is missing (empty output → caller decides).
groups_members() {
  local group="$1"
  local path
  path=$(groups_config_path)
  [ -f "$path" ] || return 0
  awk -v target="$group" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      name = $0
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\][[:space:]]*$/, "", name)
      in_section = (name == target)
      next
    }
    /^[[:space:]]*$/ { next }
    in_section {
      stack = $0
      sub(/^[[:space:]]+/, "", stack)
      sub(/[[:space:]]+$/, "", stack)
      if (stack != "") print stack
    }
  ' "$path"
}

# groups_exists <group>
#   0 if the group is declared in groups.conf (even if empty), 1 otherwise.
groups_exists() {
  local group="$1"
  groups_list | grep -Fx "$group" >/dev/null 2>&1
}

# groups_has_member <group> <stack>
#   0 if the stack appears in the group, 1 otherwise.
groups_has_member() {
  local group="$1" stack="$2"
  groups_members "$group" | grep -Fx "$stack" >/dev/null 2>&1
}

# groups_add <group> <stack>
#   Appends a stack to a group. Creates the group section if missing.
#   Idempotent — a no-op if the stack already belongs.
groups_add() {
  local group="$1" stack="$2"
  groups_ensure_config
  local path
  path=$(groups_config_path)

  if groups_has_member "$group" "$stack"; then
    return 0
  fi

  if groups_exists "$group"; then
    # Insert right after the last member line of the section.
    local tmp
    tmp=$(mktemp)
    awk -v target="$group" -v stack="$stack" '
      BEGIN { added = 0; in_section = 0 }
      /^[[:space:]]*\[.*\][[:space:]]*$/ {
        if (in_section && !added) { print stack; added = 1 }
        name = $0
        sub(/^[[:space:]]*\[/, "", name)
        sub(/\][[:space:]]*$/, "", name)
        in_section = (name == target)
        print; next
      }
      { print }
      END { if (in_section && !added) print stack }
    ' "$path" > "$tmp"
    mv "$tmp" "$path"
  else
    {
      echo ""
      echo "[$group]"
      echo "$stack"
    } >> "$path"
  fi
}

# groups_remove <group> <stack>
#   Removes a stack from a group. Idempotent.
groups_remove() {
  local group="$1" stack="$2"
  local path
  path=$(groups_config_path)
  [ -f "$path" ] || return 0

  local tmp
  tmp=$(mktemp)
  awk -v target="$group" -v stack="$stack" '
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      name = $0
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\][[:space:]]*$/, "", name)
      in_section = (name == target)
      print; next
    }
    in_section {
      line = $0
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      sub(/[[:space:]]+$/, "", trimmed)
      if (trimmed == stack) next
    }
    { print }
  ' "$path" > "$tmp"
  mv "$tmp" "$path"
}
