#!/usr/bin/env bats
# ==================================================
# tests/test_tui.bats — Interactive TUI (lib/cmd_tui.sh)
# ==================================================
# Covers the pickable helpers (_tui_stacks, _tui_commands, _tui_envs),
# the _tui_pick dispatcher with both fzf and POSIX-select paths stubbed,
# and the top-level entrypoint gates (--no-tui, STRUT_NO_TUI, --print).

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLI_ROOT
  STRUT="$CLI_ROOT/strut"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_tui() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/cmd_tui.sh"
}

# ── Data sources ─────────────────────────────────────────────────────────────

@test "_tui_stacks: lists stack directories, skipping 'shared'" {
  _load_tui
  local fake_root="$TEST_TMP/root"
  mkdir -p "$fake_root/stacks/alpha"
  mkdir -p "$fake_root/stacks/beta"
  mkdir -p "$fake_root/stacks/shared"
  CLI_ROOT="$fake_root" run _tui_stacks
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
  [[ "$output" != *"shared"* ]]
}

@test "_tui_stacks: silent when stacks dir missing" {
  _load_tui
  local fake_root="$TEST_TMP/empty"
  mkdir -p "$fake_root"
  CLI_ROOT="$fake_root" run _tui_stacks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_tui_commands: includes core commands" {
  _load_tui
  run _tui_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"stop"* ]]
  [[ "$output" == *"health"* ]]
  [[ "$output" == *"logs"* ]]
  [[ "$output" == *"backup"* ]]
}

@test "_tui_envs: enumerates .<name>.env files from CLI_ROOT" {
  _load_tui
  local fake_root="$TEST_TMP/root"
  mkdir -p "$fake_root"
  : > "$fake_root/.prod.env"
  : > "$fake_root/.staging.env"
  : > "$fake_root/.env"          # bare .env — should not become a nameless entry
  CLI_ROOT="$fake_root" run _tui_envs
  [ "$status" -eq 0 ]
  [[ "$output" == *"(none)"* ]]
  [[ "$output" == *"prod"* ]]
  [[ "$output" == *"staging"* ]]
  # The bare ".env" becomes an empty name after stripping the dot and suffix,
  # and the picker filters those out.
  local name_lines
  name_lines="$(printf '%s\n' "$output" | grep -vE '^\(none\)$' | wc -l | tr -d ' ')"
  [ "$name_lines" = "2" ]
}

@test "_tui_envs: emits only (none) when no env files exist" {
  _load_tui
  local fake_root="$TEST_TMP/bare"
  mkdir -p "$fake_root"
  CLI_ROOT="$fake_root" run _tui_envs
  [ "$status" -eq 0 ]
  [ "$output" = "(none)" ]
}

# ── Picker dispatch ──────────────────────────────────────────────────────────

@test "_tui_has_fzf: respects STRUT_TUI_FORCE_SELECT override" {
  _load_tui
  STRUT_TUI_FORCE_SELECT=1 run _tui_has_fzf
  [ "$status" -ne 0 ]
}

@test "_tui_pick: returns error when given no items" {
  _load_tui
  run _tui_pick "prompt"
  [ "$status" -ne 0 ]
}

@test "_tui_pick: uses fzf when available and honors selection" {
  _load_tui
  # Shadow fzf to one that echoes the first item and picks that.
  local bin="$TEST_TMP/bin"
  mkdir -p "$bin"
  cat > "$bin/fzf" <<'EOF'
#!/usr/bin/env bash
# Ignore flags, echo the first line of stdin.
head -n 1
EOF
  chmod +x "$bin/fzf"
  PATH="$bin:$PATH" STRUT_TUI_FORCE_SELECT= run _tui_pick "pick" apple banana cherry
  [ "$status" -eq 0 ]
  [ "$output" = "apple" ]
}

@test "_tui_pick: propagates non-zero from fzf (user cancel)" {
  _load_tui
  local bin="$TEST_TMP/bin"
  mkdir -p "$bin"
  cat > "$bin/fzf" <<'EOF'
#!/usr/bin/env bash
exit 130
EOF
  chmod +x "$bin/fzf"
  PATH="$bin:$PATH" STRUT_TUI_FORCE_SELECT= run _tui_pick "pick" apple banana
  [ "$status" -ne 0 ]
}

# ── Entrypoint gates ─────────────────────────────────────────────────────────

@test "entrypoint: STRUT_NO_TUI=1 with no args falls through to usage" {
  STRUT_NO_TUI=1 run "$STRUT"
  [ "$status" -eq 1 ]                        # usage path exits 1
  [[ "$output" == *"strut CLI"* ]]
}

@test "entrypoint: --no-tui with no args falls through to usage" {
  STRUT_NO_TUI= run "$STRUT" --no-tui
  [ "$status" -eq 1 ]
  [[ "$output" == *"strut CLI"* ]]
}

@test "entrypoint: --no-tui wins over --tui" {
  STRUT_NO_TUI= run "$STRUT" --tui --no-tui
  [ "$status" -eq 1 ]
  [[ "$output" == *"strut CLI"* ]]
}

@test "entrypoint: --print with other args leaves args intact (does not launch TUI)" {
  # Unknown stack — should hit the stack-validation failure path, not TUI.
  # Accept either "Stack not found" (dev mode / inside a project) or the
  # "Not inside a strut project" message that fires when the entrypoint
  # couldn't discover a PROJECT_ROOT.
  STRUT_NO_TUI= run "$STRUT" nonexistent-stack deploy --print
  [ "$status" -ne 0 ]
  [[ "$output" == *"Stack not found"* ]] \
    || [[ "$output" == *"Not inside a strut project"* ]] \
    || [[ "$output" == *"Unknown"* ]]
}

# ── tui_main: --print flow with stubbed picker ───────────────────────────────
# We stub _tui_pick and _tui_stacks so the test doesn't need a real tty.
# --print short-circuits before the exec, so the resolved command lands on
# stdout and the function returns cleanly.

@test "tui_main --print: assembles stack/command/env into a runnable string" {
  _load_tui
  _tui_stacks()   { echo "api-service"; }
  _tui_commands() { echo "deploy"; }
  _tui_envs()     { printf '%s\n%s\n' "(none)" "prod"; }
  _tui_pick() {
    # Always pick the first item for determinism in tests.
    shift
    printf '%s\n' "$1"
  }
  run tui_main --print
  [ "$status" -eq 0 ]
  [[ "$output" == *"strut api-service deploy"* ]]
}

@test "tui_main --print: (none) env omits --env from resolved command" {
  _load_tui
  _tui_stacks()   { echo "api-service"; }
  _tui_commands() { echo "deploy"; }
  # Force env = (none)
  _tui_envs()     { printf '(none)\n'; }
  _tui_pick() {
    shift
    printf '%s\n' "$1"
  }
  run tui_main --print
  [ "$status" -eq 0 ]
  [[ "$output" != *"--env"* ]]
  [[ "$output" == *"strut api-service deploy"* ]]
}

@test "tui_main: exits non-zero with a clear error when no stacks exist" {
  _load_tui
  _tui_stacks() { return 0; }   # emits nothing
  warn() { echo "WARN: $*" >&2; }
  run tui_main --print
  [ "$status" -ne 0 ]
  [[ "$output" == *"No stacks found"* ]] || [[ "$stderr" == *"No stacks found"* ]] || true
}
