#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_skills.bats — Smoke tests for cmd_skills dispatcher
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/cmd_skills.sh"

  # Stub installer helpers so we exercise dispatch, not filesystem writes
  _install_kiro() { echo "_install_kiro $*"; }
  _install_claude() { echo "_install_claude $*"; }
  _install_rules_file() { echo "_install_rules_file $*"; }
  _install_copilot() { echo "_install_copilot $*"; }
  _install_generic() { echo "_install_generic $*"; }
  _install_all() { echo "_install_all $*"; }
  _skills_list() { echo "_skills_list"; }
  export -f _install_kiro _install_claude _install_rules_file \
            _install_copilot _install_generic _install_all _skills_list

  # cmd_skills expects .kiro/skills to exist (that's the source tree)
  mkdir -p "$TEST_TMP/.kiro/skills"
  mkdir -p "$TEST_TMP/.kiro/steering"
  export STRUT_HOME="$TEST_TMP"
  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT"
}

teardown() {
  common_teardown
}

@test "cmd_skills: no subcommand prints usage" {
  run cmd_skills
  [ "$status" -eq 0 ]
  [[ "$output" == *"skills"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "cmd_skills: help subcommand prints usage" {
  run cmd_skills help
  [ "$status" -eq 0 ]
  [[ "$output" == *"skills"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "cmd_skills: list routes to _skills_list" {
  run cmd_skills list
  [ "$status" -eq 0 ]
  [[ "$output" == *"_skills_list"* ]]
}

@test "cmd_skills: unknown subcommand fails" {
  run cmd_skills bogus
  [[ "$output" == *"Unknown"* ]] || [[ "$output" == *"skills"* ]]
}

@test "cmd_skills install: default format kiro routes to _install_kiro" {
  run cmd_skills install
  [ "$status" -eq 0 ]
  [[ "$output" == *"_install_kiro"* ]]
}

@test "cmd_skills install: --format claude routes to _install_claude" {
  run cmd_skills install --format claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"_install_claude"* ]]
}

@test "cmd_skills install: --format=claude (equals form) works" {
  run cmd_skills install --format=claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"_install_claude"* ]]
}

@test "cmd_skills install: --format cursor routes to _install_rules_file" {
  run cmd_skills install --format cursor
  [ "$status" -eq 0 ]
  [[ "$output" == *"_install_rules_file"* ]]
  [[ "$output" == *".cursorrules"* ]]
}

@test "cmd_skills install: --format windsurf routes correctly" {
  run cmd_skills install --format windsurf
  [ "$status" -eq 0 ]
  [[ "$output" == *".windsurfrules"* ]]
}

@test "cmd_skills install: --format copilot routes to _install_copilot" {
  run cmd_skills install --format copilot
  [ "$status" -eq 0 ]
  [[ "$output" == *"_install_copilot"* ]]
}

@test "cmd_skills install: --format generic routes to _install_generic" {
  run cmd_skills install --format generic
  [ "$status" -eq 0 ]
  [[ "$output" == *"_install_generic"* ]]
}

@test "cmd_skills install: --format all routes to _install_all" {
  run cmd_skills install --format all
  [ "$status" -eq 0 ]
  [[ "$output" == *"_install_all"* ]]
}

@test "cmd_skills install: unknown format fails" {
  run cmd_skills install --format bogus
  [[ "$output" == *"Unknown format"* ]]
}

# ── Structural tests: real installers, Agent Skills spec compliance ──────────

@test "install kiro: skill lands at .kiro/skills/<name>/SKILL.md with references" {
  # Restore real installer implementations (setup() stubbed them)
  source "$CLI_ROOT/lib/cmd_skills.sh"

  # Build a fake single-skill source tree
  mkdir -p "$STRUT_HOME/.kiro/skills/strut/references"
  printf -- '---\nname: strut\ndescription: test skill\n---\n# strut\n' \
    > "$STRUT_HOME/.kiro/skills/strut/SKILL.md"
  echo "# deploy ref" > "$STRUT_HOME/.kiro/skills/strut/references/deployment.md"

  run _install_kiro "$STRUT_HOME" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]

  # Skill must be directly under .kiro/skills/strut/ (not nested deeper)
  [ -f "$PROJECT_ROOT/.kiro/skills/strut/SKILL.md" ]
  [ -f "$PROJECT_ROOT/.kiro/skills/strut/references/deployment.md" ]
  # No double-nesting
  [ ! -d "$PROJECT_ROOT/.kiro/skills/strut/strut" ]
}

@test "install kiro: skill name in SKILL.md matches its directory" {
  source "$CLI_ROOT/lib/cmd_skills.sh"

  mkdir -p "$STRUT_HOME/.kiro/skills/strut"
  printf -- '---\nname: strut\ndescription: test\n---\n' \
    > "$STRUT_HOME/.kiro/skills/strut/SKILL.md"

  _install_kiro "$STRUT_HOME" "$PROJECT_ROOT" >/dev/null

  local dir_name md_name
  dir_name=$(basename "$PROJECT_ROOT/.kiro/skills/strut")
  md_name=$(sed -n 's/^name: *//p' "$PROJECT_ROOT/.kiro/skills/strut/SKILL.md" | head -1)
  [ "$dir_name" = "$md_name" ]
}

@test "install claude: skill copied to .claude/skills/ with references" {
  source "$CLI_ROOT/lib/cmd_skills.sh"

  mkdir -p "$STRUT_HOME/.kiro/skills/strut/references"
  printf -- '---\nname: strut\ndescription: test\n---\n' \
    > "$STRUT_HOME/.kiro/skills/strut/SKILL.md"
  echo "# ref" > "$STRUT_HOME/.kiro/skills/strut/references/backups.md"

  run _install_claude "$STRUT_HOME" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]

  [ -f "$PROJECT_ROOT/.claude/skills/strut/SKILL.md" ]
  [ -f "$PROJECT_ROOT/.claude/skills/strut/references/backups.md" ]
  [ -f "$PROJECT_ROOT/CLAUDE.md" ]
}
