#!/usr/bin/env bats
# ==================================================
# tests/test_completions_sync.bats — Completions vs dispatch-table sync
# ==================================================
# Statically diffs the command lists baked into completions/{bash,zsh,fish}
# against the actual `case "${1:-}" in` (top-level) and `case "$COMMAND" in`
# (per-stack) dispatch arms in `strut`, so a new command can't silently ship
# without tab completion in any shell.
#
# Run:  bats tests/test_completions_sync.bats

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STRUT_BIN="$CLI_ROOT/strut"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── Helpers ──────────────────────────────────────────────────────────────

# _dispatch_arms <start-substring>
# Extracts the raw (possibly |-joined) arm labels of the LAST top-level
# (nesting depth 0) case block in `strut` whose opening line contains
# <start-substring> (a literal substring match, not a regex — this avoids
# awk-version-dependent handling of backslash escapes in -v assignments).
# Nesting depth is tracked so inner case blocks (e.g.
# monitoring/notify subcommands, or the small host-scoped-detection and
# --help usage-dispatch case blocks that share the same "in" text earlier
# in the file) are not mistaken for the real dispatch table.
_dispatch_arms() {
  local start="$1"
  awk -v start="$start" '
    BEGIN { depth = 0; capturing = 0; n = 0 }
    {
      line = $0
      is_case_open = (line ~ /(^|[^A-Za-z_])case[ \t]+.*[ \t]+in[ \t]*$/)
      is_esac      = (line ~ /^[ \t]*esac[ \t]*(;;)?[ \t]*$/)

      if (!capturing && depth == 0 && index(line, start) > 0) {
        capturing = 1; depth = 1; n = 0; delete arr
        next
      }
      if (capturing) {
        if (is_case_open) { depth++; next }
        if (is_esac) { depth--; if (depth == 0) capturing = 0; next }
        if (depth == 1) {
          t = line
          gsub(/^[ \t]+/, "", t); gsub(/[ \t]+$/, "", t)
          if (t ~ /^[A-Za-z0-9_:.*$|"-]+\)/) {
            idx = index(t, ")")
            arr[++n] = substr(t, 1, idx - 1)
          }
        }
      }
    }
    END { for (i = 1; i <= n; i++) print arr[i] }
  ' "$STRUT_BIN"
}

# _dispatch_commands <start-pattern>
# Expands |-joined arm labels into individual command tokens, dropping
# flag-only alias arms (--version|-v|version, --help|-h|help) and
# housekeeping arms (the "*" plugin-fallthrough/unknown-command arm and the
# "" missing-argument arm).
_dispatch_commands() {
  local start="$1" arm token first
  while IFS= read -r arm; do
    [ -z "$arm" ] && continue
    IFS='|' read -ra toks <<< "$arm"
    first="${toks[0]}"
    [ "$first" = '*' ] && continue
    [ "$first" = '""' ] && continue
    [[ "$first" == -* ]] && continue
    for token in "${toks[@]}"; do
      [[ "$token" == -* ]] && continue
      printf '%s\n' "$token"
    done
  done < <(_dispatch_arms "$start")
}

# _word_list_commands <word...> — filters a flat completion command list
# down to real command tokens (drops --flags/-f short flags).
_word_list_commands() {
  local w
  for w in "$@"; do
    [[ "$w" == -* ]] && continue
    printf '%s\n' "$w"
  done
}

# _missing <needle-file> <haystack-file> — lines present in needle but not
# in haystack (i.e. dispatch commands the completion file forgot).
_missing() {
  comm -23 <(sort -u "$1") <(sort -u "$2")
}

_dispatch_top() {
  _dispatch_commands 'case "${1:-}" in' | sort -u
}

_dispatch_stack() {
  _dispatch_commands 'case "$COMMAND" in' | sort -u
}

# ── bash ─────────────────────────────────────────────────────────────────

@test "completions/bash.sh top_cmds covers every top-level dispatch command" {
  _dispatch_top > "$TEST_TMP/dispatch_top.txt"
  # shellcheck disable=SC2046
  _word_list_commands $(sed -n 's/^[[:space:]]*local top_cmds="\(.*\)"$/\1/p' "$CLI_ROOT/completions/bash.sh") \
    | sort -u > "$TEST_TMP/have.txt"

  local missing
  missing=$(_missing "$TEST_TMP/dispatch_top.txt" "$TEST_TMP/have.txt")
  if [ -n "$missing" ]; then
    echo "completions/bash.sh top_cmds is missing commands dispatched by strut:" >&2
    echo "$missing" >&2
    return 1
  fi
}

@test "completions/bash.sh per_stack_cmds covers every per-stack dispatch command" {
  _dispatch_stack > "$TEST_TMP/dispatch_stack.txt"
  # shellcheck disable=SC2046
  _word_list_commands $(sed -n 's/^[[:space:]]*local per_stack_cmds="\(.*\)"$/\1/p' "$CLI_ROOT/completions/bash.sh") \
    | sort -u > "$TEST_TMP/have.txt"

  local missing
  missing=$(_missing "$TEST_TMP/dispatch_stack.txt" "$TEST_TMP/have.txt")
  if [ -n "$missing" ]; then
    echo "completions/bash.sh per_stack_cmds is missing commands dispatched by strut:" >&2
    echo "$missing" >&2
    return 1
  fi
}

# ── zsh ──────────────────────────────────────────────────────────────────

@test "completions/zsh.sh top_cmds covers every top-level dispatch command" {
  _dispatch_top > "$TEST_TMP/dispatch_top.txt"
  # shellcheck disable=SC2046
  _word_list_commands $(sed -n 's/^[[:space:]]*top_cmds=(\(.*\))$/\1/p' "$CLI_ROOT/completions/zsh.sh") \
    | sort -u > "$TEST_TMP/have.txt"

  local missing
  missing=$(_missing "$TEST_TMP/dispatch_top.txt" "$TEST_TMP/have.txt")
  if [ -n "$missing" ]; then
    echo "completions/zsh.sh top_cmds is missing commands dispatched by strut:" >&2
    echo "$missing" >&2
    return 1
  fi
}

@test "completions/zsh.sh per_stack_cmds covers every per-stack dispatch command" {
  _dispatch_stack > "$TEST_TMP/dispatch_stack.txt"
  # shellcheck disable=SC2046
  _word_list_commands $(sed -n 's/^[[:space:]]*per_stack_cmds=(\(.*\))$/\1/p' "$CLI_ROOT/completions/zsh.sh") \
    | sort -u > "$TEST_TMP/have.txt"

  local missing
  missing=$(_missing "$TEST_TMP/dispatch_stack.txt" "$TEST_TMP/have.txt")
  if [ -n "$missing" ]; then
    echo "completions/zsh.sh per_stack_cmds is missing commands dispatched by strut:" >&2
    echo "$missing" >&2
    return 1
  fi
}

# ── fish ─────────────────────────────────────────────────────────────────

@test "completions/fish.fish top_cmds covers every top-level dispatch command" {
  _dispatch_top > "$TEST_TMP/dispatch_top.txt"
  # shellcheck disable=SC2046
  _word_list_commands $(sed -n 's/^set -l top_cmds \(.*\)$/\1/p' "$CLI_ROOT/completions/fish.fish") \
    | sort -u > "$TEST_TMP/have.txt"

  local missing
  missing=$(_missing "$TEST_TMP/dispatch_top.txt" "$TEST_TMP/have.txt")
  if [ -n "$missing" ]; then
    echo "completions/fish.fish top_cmds is missing commands dispatched by strut:" >&2
    echo "$missing" >&2
    return 1
  fi
}

@test "completions/fish.fish per_stack_cmds covers every per-stack dispatch command" {
  _dispatch_stack > "$TEST_TMP/dispatch_stack.txt"
  # shellcheck disable=SC2046
  _word_list_commands $(sed -n 's/^set -l per_stack_cmds \(.*\)$/\1/p' "$CLI_ROOT/completions/fish.fish") \
    | sort -u > "$TEST_TMP/have.txt"

  local missing
  missing=$(_missing "$TEST_TMP/dispatch_stack.txt" "$TEST_TMP/have.txt")
  if [ -n "$missing" ]; then
    echo "completions/fish.fish per_stack_cmds is missing commands dispatched by strut:" >&2
    echo "$missing" >&2
    return 1
  fi
}

# ── Sanity: the parser itself finds a non-trivial dispatch table ─────────
# Guards against the awk parser silently matching nothing (e.g. after a
# `strut` refactor changes the case-statement shape) and every test above
# passing vacuously.

@test "dispatch parser: finds a substantial top-level and per-stack command set" {
  local top_count stack_count
  top_count=$(_dispatch_top | wc -l)
  stack_count=$(_dispatch_stack | wc -l)
  [ "$top_count" -gt 10 ]
  [ "$stack_count" -gt 20 ]
}
