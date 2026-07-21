#!/usr/bin/env bats
# ==================================================
# tests/test_cli_dispatch.bats — CLI dispatch & arg parsing tests
# ==================================================
# Run:  bats tests/test_cli_dispatch.bats
# Covers: top-level routing, unknown commands, help, list, stack validation

setup() {
  CLI="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/strut"
}

# ── Help & usage ──────────────────────────────────────────────────────────────

@test "strut --help exits 0 and shows usage" {
  run bash "$CLI" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"strut CLI"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "strut -h exits 0" {
  run bash "$CLI" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "strut help exits 0" {
  run bash "$CLI" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "strut with no args exits 1 and shows usage" {
  run bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# ── list command ──────────────────────────────────────────────────────────────

@test "strut list shows available stacks header" {
  run bash "$CLI" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Available stacks"* ]]
}

@test "strut --list works as alias" {
  run bash "$CLI" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Available stacks"* ]]
}

@test "strut -l works as alias" {
  run bash "$CLI" -l
  [ "$status" -eq 0 ]
  [[ "$output" == *"Available stacks"* ]]
}

# ── Stack validation ──────────────────────────────────────────────────────────

@test "strut with nonexistent stack fails" {
  run bash "$CLI" nonexistent-stack deploy
  [ "$status" -ne 0 ]
  # When run outside any initialized project the entrypoint emits the
  # clearer "Not inside a strut project" message; inside a project it
  # falls through to "Stack not found". Either outcome satisfies this
  # test — both confirm that a bogus stack name doesn't dispatch.
  [[ "$output" == *"Stack not found"* ]] || [[ "$output" == *"Not inside a strut project"* ]]
}

@test "strut with valid stack but no command fails" {
  # Create a temporary stack so we can test command dispatch
  local cli_root="$(dirname "$CLI")"
  mkdir -p "$cli_root/stacks/test-stack"
  touch "$cli_root/stacks/test-stack/docker-compose.yml"
  run bash "$CLI" test-stack
  rm -rf "$cli_root/stacks/test-stack"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing command"* ]]
}

@test "strut with valid stack and unknown command fails" {
  local cli_root="$(dirname "$CLI")"
  mkdir -p "$cli_root/stacks/test-stack"
  touch "$cli_root/stacks/test-stack/docker-compose.yml"
  run bash "$CLI" test-stack foobar
  rm -rf "$cli_root/stacks/test-stack"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
}

# ── Scaffold validation ──────────────────────────────────────────────────────

@test "strut scaffold with no name fails" {
  run bash "$CLI" scaffold
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "strut scaffold with existing stack fails" {
  # scaffold now requires PROJECT_ROOT (strut#403 — otherwise it silently
  # wrote into the engine's own stacks/ dir), so this needs a real project
  # dir with a strut.conf rather than reusing the engine repo directly.
  local project_dir
  project_dir="$(mktemp -d)"
  touch "$project_dir/strut.conf"
  mkdir -p "$project_dir/stacks/existing-stack"

  run env STRUT_PROJECT="$project_dir" bash "$CLI" scaffold existing-stack
  rm -rf "$project_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}
