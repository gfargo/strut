#!/usr/bin/env bash
# ==================================================
# lib/output.sh — Table + JSON rendering helpers
# ==================================================
# Unifies list/status/audit command output. Supports plain tables, JSON,
# and a shared NO_COLOR / non-tty fallback so CI logs stay readable.
#
# Usage — table:
#   out_table_header "Stack" "Health" "Last Deploy"
#   out_table_row "api" "✓ healthy" "2h ago"
#   out_table_row "worker" "⚠ degraded" "1d ago"
#   out_table_render
#
# Usage — JSON (streamed; no buffering):
#   out_json_object
#     out_json_field env prod
#     out_json_array stacks
#       out_json_object
#         out_json_field name api
#         out_json_field health healthy
#       out_json_close_object
#     out_json_close_array
#   out_json_close_object
#
# Mode selection:
#   OUTPUT_MODE=json  → JSON helpers emit real JSON; table helpers are no-ops
#   OUTPUT_MODE=text  → Table helpers render; JSON helpers are no-ops
#   (unset)           → defaults to text; callers usually flip via --json

set -euo pipefail

# ── Internal state ────────────────────────────────────────────────────────────
_OUT_TABLE_COLS=()
_OUT_TABLE_ROWS=()       # Rows stored TSV-encoded (fields joined by \t)
_OUT_TABLE_WIDTHS=()

_OUT_JSON_STACK=()        # Stack of "object" | "array"
_OUT_JSON_FIRST=()        # Parallel stack: 1 = first item in container

# ── Environment helpers ───────────────────────────────────────────────────────

# output_is_tty — returns 0 if stdout is a terminal
output_is_tty() {
  [ -t 1 ]
}

# output_use_color — returns 0 if color output is appropriate
output_use_color() {
  [ -z "${NO_COLOR:-}" ] && output_is_tty
}

# output_mode — resolves the effective mode (text|json)
output_mode() {
  case "${OUTPUT_MODE:-text}" in
    json) echo json ;;
    *)    echo text ;;
  esac
}

# ── Table renderer ────────────────────────────────────────────────────────────

# out_table_reset — clear any buffered table state
out_table_reset() {
  _OUT_TABLE_COLS=()
  _OUT_TABLE_ROWS=()
  _OUT_TABLE_WIDTHS=()
}

# out_table_header <col1> [col2...]
#
# Set column headers. Must be called before out_table_row.
out_table_header() {
  [ "$(output_mode)" = "json" ] && return 0
  _OUT_TABLE_COLS=("$@")
  _OUT_TABLE_WIDTHS=()
  local c
  for c in "$@"; do
    _OUT_TABLE_WIDTHS+=("${#c}")
  done
}

# out_table_row <val1> [val2...]
#
# Append a row. Values may contain ANSI color codes — width accounting
# strips them so alignment stays correct.
out_table_row() {
  [ "$(output_mode)" = "json" ] && return 0
  local i=0 v plain
  local -a row=("$@")
  # Track max width per column (based on visible/plain length)
  for v in "$@"; do
    plain=$(_out_strip_ansi "$v")
    if [ "$i" -lt "${#_OUT_TABLE_WIDTHS[@]}" ]; then
      [ "${#plain}" -gt "${_OUT_TABLE_WIDTHS[i]}" ] && _OUT_TABLE_WIDTHS[i]=${#plain}
    else
      _OUT_TABLE_WIDTHS+=("${#plain}")
    fi
    i=$((i + 1))
  done
  # Join with tab — tab is safe since we don't expect tabs in cell values
  local IFS=$'\t'
  _OUT_TABLE_ROWS+=("${row[*]}")
}

# out_table_render — emit the buffered table to stdout and reset
out_table_render() {
  [ "$(output_mode)" = "json" ] && { out_table_reset; return 0; }

  # Header
  if [ "${#_OUT_TABLE_COLS[@]}" -gt 0 ]; then
    _out_print_row "$(output_use_color && echo 1 || echo 0)" "header" "${_OUT_TABLE_COLS[@]}"
    _out_print_separator
  fi

  # Rows
  local row
  local IFS=$'\t'
  for row in "${_OUT_TABLE_ROWS[@]+"${_OUT_TABLE_ROWS[@]}"}"; do
    local -a fields
    read -r -a fields <<<"$row"
    _out_print_row "$(output_use_color && echo 1 || echo 0)" "cell" "${fields[@]}"
  done

  out_table_reset
}

# out_table_empty <message>
#
# Render a consistent "no results" line when the table would be empty.
out_table_empty() {
  [ "$(output_mode)" = "json" ] && return 0
  local msg="${1:-(no results)}"
  if output_use_color; then
    printf '%b%s%b\n' "\033[2m" "$msg" "\033[0m"
  else
    printf '%s\n' "$msg"
  fi
}

# ── Internal table helpers ────────────────────────────────────────────────────

# _out_strip_ansi <text> — strip ESC[... codes for width accounting
_out_strip_ansi() {
  # Portable sed without GNU extensions: use perl-style escape
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

_out_print_row() {
  local color="$1"; shift
  local kind="$1"; shift
  local i=0 val pad plain width out=""
  for val in "$@"; do
    width="${_OUT_TABLE_WIDTHS[$i]}"
    plain=$(_out_strip_ansi "$val")
    pad=$((width - ${#plain}))
    if [ "$color" = "1" ] && [ "$kind" = "header" ]; then
      out+=$(printf '\033[1m%s\033[0m' "$val")
    else
      out+="$val"
    fi
    if [ "$pad" -gt 0 ]; then
      out+=$(printf '%*s' "$pad" '')
    fi
    i=$((i + 1))
    [ "$i" -lt "$#" ] && out+="  "
  done
  printf '%s\n' "$out"
}

_out_print_separator() {
  local total=0 w
  for w in "${_OUT_TABLE_WIDTHS[@]}"; do
    total=$((total + w))
  done
  # Account for 2-char gutters between columns
  local gutters=$((${#_OUT_TABLE_WIDTHS[@]} > 0 ? (${#_OUT_TABLE_WIDTHS[@]} - 1) * 2 : 0))
  total=$((total + gutters))
  printf '%*s\n' "$total" '' | tr ' ' '-'
}

# ── JSON renderer ─────────────────────────────────────────────────────────────
# Streaming helpers — emit JSON tokens directly to stdout. Callers maintain
# structure by calling open/close in matching pairs. No buffering means
# large result sets don't blow up memory.

# _out_json_enabled — returns 0 if we should emit JSON
_out_json_enabled() {
  [ "$(output_mode)" = "json" ]
}

# _out_json_escape <string> — escape for JSON string literal (stdin passthrough)
_out_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

_out_json_comma_if_needed() {
  if [ "${#_OUT_JSON_STACK[@]}" -gt 0 ]; then
    local depth=$((${#_OUT_JSON_STACK[@]} - 1))
    if [ "${_OUT_JSON_FIRST[$depth]}" = "1" ]; then
      _OUT_JSON_FIRST[depth]=0
    else
      printf ','
    fi
  fi
}

# out_json_object — open an object. Use inside an array or at top level.
out_json_object() {
  _out_json_enabled || return 0
  _out_json_comma_if_needed
  printf '{'
  _OUT_JSON_STACK+=("object")
  _OUT_JSON_FIRST+=("1")
}

# out_json_close_object — close the current object
out_json_close_object() {
  _out_json_enabled || return 0
  printf '}'
  unset '_OUT_JSON_STACK[-1]'
  unset '_OUT_JSON_FIRST[-1]'
}

# out_json_array <key> — open a keyed array inside an object
out_json_array() {
  _out_json_enabled || return 0
  local key="$1"
  _out_json_comma_if_needed
  printf '"%s":[' "$(_out_json_escape "$key")"
  _OUT_JSON_STACK+=("array")
  _OUT_JSON_FIRST+=("1")
}

# out_json_close_array — close the current array
out_json_close_array() {
  _out_json_enabled || return 0
  printf ']'
  unset '_OUT_JSON_STACK[-1]'
  unset '_OUT_JSON_FIRST[-1]'
}

# out_json_field <key> <value>
#
# Emit a string-valued key. Value is JSON-escaped. Use out_json_field_raw
# for booleans or numbers (caller responsible for validity).
out_json_field() {
  _out_json_enabled || return 0
  local key="$1" val="$2"
  _out_json_comma_if_needed
  printf '"%s":"%s"' "$(_out_json_escape "$key")" "$(_out_json_escape "$val")"
}

# out_json_field_raw <key> <raw_value>
#
# Emit key with unquoted raw value — used for booleans, numbers, nested JSON.
out_json_field_raw() {
  _out_json_enabled || return 0
  local key="$1" val="$2"
  _out_json_comma_if_needed
  printf '"%s":%s' "$(_out_json_escape "$key")" "$val"
}

# out_json_string <value>
#
# Emit a bare string inside an array (no key).
out_json_string() {
  _out_json_enabled || return 0
  local val="$1"
  _out_json_comma_if_needed
  printf '"%s"' "$(_out_json_escape "$val")"
}

# out_json_newline — emit a trailing newline after the root value closes
out_json_newline() {
  _out_json_enabled || return 0
  printf '\n'
}

# out_json_reset — clear any partial JSON state (for error recovery)
out_json_reset() {
  _OUT_JSON_STACK=()
  _OUT_JSON_FIRST=()
}
