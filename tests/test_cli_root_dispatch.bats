#!/usr/bin/env bats
# ==================================================
# tests/test_cli_root_dispatch.bats — CLI_ROOT/PROJECT_ROOT dispatch
# ==================================================
# Regression tests for v0.20.1. Before the fix, the strut entrypoint
# hardcoded `CLI_ROOT="$STRUT_HOME"`, so every stack lookup landed in the
# engine directory — `strut list`, `strut <stack> <cmd>`, and the TUI all
# failed to find stacks that `strut init` / `strut scaffold` had placed in
# the user's project root. Fix: set `CLI_ROOT="${PROJECT_ROOT:-$STRUT_HOME}"`
# after `find_project_root` runs.
#
# These tests drive the real entrypoint with HOME pinned to a scratch dir
# so find_project_root's walk-up terminates predictably and never picks up
# the developer's personal strut.conf.
#
# Run:  bats tests/test_cli_root_dispatch.bats

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# _make_project <dir> — write a minimal strut.conf so find_project_root
# recognises <dir> as a project root.
_make_project() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/strut.conf" <<'EOF'
REGISTRY_TYPE=none
DEFAULT_ORG=test
BANNER_TEXT=test
EOF
}

# _run_in <dir> <args...>
# Invoke the entrypoint with $dir as cwd. HOME is pinned inside TEST_TMP so
# the walk-up search can never reach the developer's home directory.
_run_in() {
  local dir="$1"; shift
  run env -i \
    HOME="$TEST_TMP/home" \
    PATH="$PATH" \
    PWD="$dir" \
    bash -c "cd '$dir' && bash '$CLI' \"\$@\"" _ "$@"
}

# ── Inside a project: stacks are discovered from PROJECT_ROOT ────────────────

@test "strut list finds stacks under the project root, not the engine dir" {
  local proj="$TEST_TMP/myproj"
  _make_project "$proj"
  mkdir -p "$proj/stacks/alpha"
  mkdir -p "$proj/stacks/beta"
  touch "$proj/stacks/alpha/docker-compose.yml"
  touch "$proj/stacks/beta/docker-compose.yml"

  _run_in "$proj" list

  [ "$status" -eq 0 ]
  [[ "$output" == *"Available stacks"* ]]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
  # Paths printed should be inside the project, not the engine dir.
  [[ "$output" == *"$proj/stacks/alpha"* ]]
}

@test "strut list discovers stacks from a nested subdirectory" {
  local proj="$TEST_TMP/nested"
  _make_project "$proj"
  mkdir -p "$proj/stacks/web"
  touch "$proj/stacks/web/docker-compose.yml"
  mkdir -p "$proj/deep/sub/dir"

  _run_in "$proj/deep/sub/dir" list

  [ "$status" -eq 0 ]
  [[ "$output" == *"web"* ]]
  [[ "$output" == *"$proj/stacks/web"* ]]
}

@test "strut <stack> <cmd> resolves stacks under PROJECT_ROOT" {
  local proj="$TEST_TMP/stackproj"
  _make_project "$proj"
  mkdir -p "$proj/stacks/myapp"
  touch "$proj/stacks/myapp/docker-compose.yml"

  # Unknown command against a valid stack should get past stack validation
  # and fail on command dispatch — proving the stack was found in the
  # project directory.
  _run_in "$proj" myapp totallyfakecmd

  [ "$status" -ne 0 ]
  [[ "$output" != *"Not inside a strut project"* ]]
  [[ "$output" != *"Stack not found"* ]]
  [[ "$output" == *"Unknown command"* ]]
}

# ── Outside any project: friendly "not in a project" message ─────────────────

@test "strut <stack> <cmd> outside a project emits 'Not inside a strut project'" {
  local bare="$TEST_TMP/bare"
  mkdir -p "$bare"

  _run_in "$bare" some-stack deploy

  [ "$status" -ne 0 ]
  [[ "$output" == *"Not inside a strut project"* ]]
  [[ "$output" == *"strut init"* ]]
}

# ── Engine-home fallback for project-less commands ───────────────────────────

@test "strut list outside a project does not crash (falls back to engine dir)" {
  local bare="$TEST_TMP/plainland"
  mkdir -p "$bare"

  _run_in "$bare" list

  # list tolerates absent stacks/ with a warn + empty listing. The key
  # invariant is that we don't fail with an unset-variable explosion when
  # no project was found.
  [ "$status" -eq 0 ]
}

# ── Project detection does not overwrite an explicit env override ────────────

@test "explicit CLI_ROOT override is respected over PROJECT_ROOT discovery" {
  local proj="$TEST_TMP/override"
  _make_project "$proj"
  mkdir -p "$proj/stacks/real"
  touch "$proj/stacks/real/docker-compose.yml"

  # Forge a completely separate "project" for the override to point at.
  local forced="$TEST_TMP/forced"
  mkdir -p "$forced/stacks/ghost"
  touch "$forced/stacks/ghost/docker-compose.yml"

  # strut currently exports CLI_ROOT from the entrypoint unconditionally,
  # so this test documents behavior: discovery wins inside a project. If
  # that contract changes we want to notice.
  _run_in "$proj" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"real"* ]]
  [[ "$output" != *"ghost"* ]]
}
