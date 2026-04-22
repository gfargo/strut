#!/usr/bin/env bash
# ==================================================
# lib/cmd_tui.sh — Interactive TUI for stack/command navigation
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Provides a zero-argument interactive picker: stack → command → env →
# confirm → run. Uses fzf when available, falls back to POSIX `select`
# otherwise. Disabled when:
#   - stdin is not a terminal (piped, scripted, CI)
#   - STRUT_NO_TUI=1 is set
#   - --no-tui is the first argument
#
# Public entry point:
#   tui_main [--print]
#
# Helpers are underscore-prefixed and are intentionally small so tests can
# stub them individually.

set -euo pipefail

# ── Picker dispatch ──────────────────────────────────────────────────────────

# _tui_has_fzf — 0 if fzf is on PATH and the user hasn't forced fallback.
_tui_has_fzf() {
  [ "${STRUT_TUI_FORCE_SELECT:-}" = "1" ] && return 1
  command -v fzf >/dev/null 2>&1
}

# _tui_pick <prompt> <items...>
#
# Renders a picker and writes the chosen item to stdout. Returns non-zero
# if the user cancelled (ctrl-c, empty select input). Always reads from and
# writes to /dev/tty so bats can capture function output without the picker
# UI bleeding into it.
_tui_pick() {
  local prompt="$1"; shift
  [ $# -eq 0 ] && return 1

  if _tui_has_fzf; then
    local choice
    choice="$(printf '%s\n' "$@" | fzf --prompt="$prompt > " --height=40% --reverse --no-multi)" || return 1
    [ -z "$choice" ] && return 1
    printf '%s\n' "$choice"
    return 0
  fi

  # POSIX fallback: `select` reads from /dev/tty and writes the menu to
  # stderr; we capture the user's choice without polluting stdout.
  {
    echo ""
    echo "$prompt"
  } >&2
  local reply
  select reply in "$@"; do
    if [ -n "$reply" ]; then
      printf '%s\n' "$reply"
      return 0
    fi
    echo "  (invalid — pick a number)" >&2
  done < /dev/tty
  return 1
}

# ── Data sources ─────────────────────────────────────────────────────────────

# _tui_stacks — one stack name per line (no trailing slashes, skips "shared")
_tui_stacks() {
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  [ -d "$cli_root/stacks" ] || return 0
  local dir name
  for dir in "$cli_root/stacks"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    [ "$name" = "shared" ] && continue
    printf '%s\n' "$name"
  done
}

# _tui_commands — catalog of interactive commands surfaced in the TUI.
# Kept short on purpose — anything the user rarely reaches for (audit,
# migrate wizard, notify test, etc.) is left to explicit CLI invocation.
_tui_commands() {
  cat <<'EOF'
deploy
stop
health
status
logs
backup
drift
validate
shell
rollback
EOF
}

# _tui_envs — discovered env names from `$CLI_ROOT/.<name>.env` files.
# Always includes "(none)" so the user can deliberately run without an env.
_tui_envs() {
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  printf '%s\n' "(none)"
  local f base name
  for f in "$cli_root"/.*.env; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"        # .prod.env
    name="${base#.}"               # prod.env
    name="${name%.env}"            # prod
    # Skip empty and sentinel entries like `.env` (which becomes "")
    [ -z "$name" ] && continue
    printf '%s\n' "$name"
  done
}

# ── Confirmation + exec ──────────────────────────────────────────────────────

# _tui_confirm <prompt>
# Returns 0 if user answers yes, 1 otherwise. Reads from /dev/tty.
_tui_confirm() {
  local prompt="$1"
  local reply=""
  echo "" >&2
  printf '%s [y/N] ' "$prompt" >&2
  read -r reply < /dev/tty || return 1
  case "$reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Main driver ──────────────────────────────────────────────────────────────

# tui_main [--print]
#
# Walks the user through: stack → command → env → confirm. Prints the
# resolved command if --print is supplied, otherwise execs it.
tui_main() {
  local print_only=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --print) print_only=true; shift ;;
      --help|-h)
        echo "Usage: strut (no args)        # launches TUI"
        echo "       strut --no-tui         # disables, shows usage"
        echo "       STRUT_NO_TUI=1 strut   # permanent disable"
        echo ""
        echo "Flags (within TUI):"
        echo "  --print   Print the resolved command instead of running it"
        return 0
        ;;
      *) shift ;;
    esac
  done

  echo "" >&2
  echo "strut — interactive mode (pass --no-tui to disable)" >&2

  # ── Pick stack ─────────────────────────────────────────────────────────────
  local stacks
  stacks="$(_tui_stacks)"
  if [ -z "$stacks" ]; then
    warn "No stacks found under $CLI_ROOT/stacks — run 'strut scaffold <name>' first"
    return 1
  fi

  local stack
  # shellcheck disable=SC2046
  stack="$(_tui_pick "Stack" $(printf '%s ' $stacks))" || { echo "cancelled" >&2; return 130; }

  # ── Pick command ───────────────────────────────────────────────────────────
  local commands
  commands="$(_tui_commands)"
  local command
  # shellcheck disable=SC2046
  command="$(_tui_pick "Command for '$stack'" $(printf '%s ' $commands))" || { echo "cancelled" >&2; return 130; }

  # ── Pick env ───────────────────────────────────────────────────────────────
  local envs env
  envs="$(_tui_envs)"
  # shellcheck disable=SC2046
  env="$(_tui_pick "Env for '$stack $command'" $(printf '%s ' $envs))" || { echo "cancelled" >&2; return 130; }

  # ── Build command ──────────────────────────────────────────────────────────
  local argv=("$stack" "$command")
  if [ "$env" != "(none)" ]; then
    argv+=(--env "$env")
  fi

  local resolved
  resolved="strut ${argv[*]}"

  if $print_only; then
    printf '%s\n' "$resolved"
    return 0
  fi

  echo "" >&2
  echo "Resolved: $resolved" >&2
  if ! _tui_confirm "Run this command?"; then
    echo "cancelled" >&2
    return 130
  fi

  # Re-exec through the entrypoint so the user gets the same behavior
  # as if they'd typed the full command.
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  exec "$cli_root/strut" "${argv[@]}"
}
