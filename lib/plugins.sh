#!/usr/bin/env bash
# ==================================================
# lib/plugins.sh — Project-local plugin discovery & dispatch
# ==================================================
#
# Plugins let operators extend strut with custom commands without forking.
# Drop a file in .strut/plugins/cmd_<name>.sh under PROJECT_ROOT and strut
# will discover it on startup and dispatch `strut <name> ...` (top-level)
# or `strut <stack> <name> ...` (stack-level) to it.
#
# Plugin contract (bash):
#   plugin_help()   — prints one-line description on stdout
#   plugin_main()   — receives dispatched args; first two args are stack
#                     and env_name when invoked in stack-level context
#
# Precedence: core strut commands always win. Plugins fall through only
# when the command name doesn't match any core case.
#
# Isolation: plugins run in a subshell, so a plugin crash (set -e, exit,
# unbound var) does not take down strut.
#
# Re-entrancy: plugins can call `strut` themselves — the entrypoint is on
# PATH for the operator's shell.

set -euo pipefail

# Parallel arrays rather than associative — keeps bash 3 portability that
# other lib/*.sh relies on.
_STRUT_PLUGIN_NAMES=()
_STRUT_PLUGIN_FILES=()

# plugins_dir — resolve the directory strut scans for plugins.
# Honors PROJECT_ROOT (set by lib/config.sh). Absent PROJECT_ROOT, returns
# a path under $PWD so repeated invocations remain deterministic.
plugins_dir() {
  echo "${PROJECT_ROOT:-$PWD}/.strut/plugins"
}

# plugins_discover — (re)populate the plugin registry from plugins_dir.
# Silent no-op when the directory doesn't exist. Called once at startup
# and safe to call repeatedly (e.g. from tests).
plugins_discover() {
  _STRUT_PLUGIN_NAMES=()
  _STRUT_PLUGIN_FILES=()
  local dir
  dir="$(plugins_dir)"
  [ -d "$dir" ] || return 0

  local f name
  for f in "$dir"/cmd_*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .sh)"
    name="${name#cmd_}"
    [ -n "$name" ] || continue
    _STRUT_PLUGIN_NAMES+=("$name")
    _STRUT_PLUGIN_FILES+=("$f")
  done
}

# plugins_file_for <name> — print the file path for a plugin, or return 1.
plugins_file_for() {
  local want="$1" i
  local count="${#_STRUT_PLUGIN_NAMES[@]}"
  [ "$count" -eq 0 ] && return 1
  for ((i = 0; i < count; i++)); do
    if [ "${_STRUT_PLUGIN_NAMES[i]}" = "$want" ]; then
      printf '%s\n' "${_STRUT_PLUGIN_FILES[i]}"
      return 0
    fi
  done
  return 1
}

# plugins_has <name> — predicate for dispatch fallthrough checks.
plugins_has() {
  plugins_file_for "$1" >/dev/null 2>&1
}

# plugins_run <name> [args...] — source the plugin in a subshell and call
# plugin_main. Subshell keeps plugin state out of strut's process and
# prevents plugin exit/set -e from killing the CLI.
plugins_run() {
  local name="$1"; shift
  local file
  file="$(plugins_file_for "$name")" || { fail "Plugin not found: $name"; }
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$file"
    if ! declare -F plugin_main >/dev/null 2>&1; then
      echo "[strut] plugin '$name' does not define plugin_main()" >&2
      exit 1
    fi
    plugin_main "$@"
  )
}

# plugins_help <name> — invoke plugin_help in a subshell. Returns an
# empty string (not error) when the plugin omits plugin_help, so list
# rendering stays tidy.
plugins_help() {
  local name="$1"
  local file
  file="$(plugins_file_for "$name")" || { fail "Plugin not found: $name"; }
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$file"
    if declare -F plugin_help >/dev/null 2>&1; then
      plugin_help
    fi
  )
}

# plugins_list_text — render discovered plugins as a table.
plugins_list_text() {
  local dir
  dir="$(plugins_dir)"

  if [ "${#_STRUT_PLUGIN_NAMES[@]}" -eq 0 ]; then
    echo ""
    echo "No plugins found."
    echo "Plugins dir: $dir"
    echo ""
    echo "Drop a cmd_<name>.sh file in that directory with plugin_main/"
    echo "plugin_help and re-run to pick it up."
    echo ""
    return 0
  fi

  echo ""
  echo -e "${BLUE:-}Plugins:${NC:-}"
  echo ""
  out_table_header "Name" "Description" "File"
  local i name file desc
  for i in "${!_STRUT_PLUGIN_NAMES[@]}"; do
    name="${_STRUT_PLUGIN_NAMES[i]}"
    file="${_STRUT_PLUGIN_FILES[i]}"
    desc="$(plugins_help "$name" 2>/dev/null | head -1 || true)"
    [ -n "$desc" ] || desc="(no description)"
    out_table_row "$name" "$desc" "$file"
  done
  out_table_render
  echo ""
}

# plugins_list_json — stream discovered plugins as JSON.
plugins_list_json() {
  out_json_object
    out_json_field "plugins_dir" "$(plugins_dir)"
    out_json_array "plugins"
    local i name file desc count="${#_STRUT_PLUGIN_NAMES[@]}"
    for ((i = 0; i < count; i++)); do
      name="${_STRUT_PLUGIN_NAMES[i]}"
      file="${_STRUT_PLUGIN_FILES[i]}"
      desc="$(plugins_help "$name" 2>/dev/null | head -1 || true)"
      out_json_object
        out_json_field "name" "$name"
        out_json_field "description" "$desc"
        out_json_field "file" "$file"
      out_json_close_object
    done
    out_json_close_array
  out_json_close_object
  out_json_newline
}
