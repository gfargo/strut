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
  # Force the direct-copy fallback deterministically — without this, whether
  # the test exercises agent-add or the fallback depends on whether the CI
  # runner happens to have a working npx, which is exactly what this test
  # must not depend on.
  _agent_add_install_skills() { return 1; }

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
  _agent_add_install_skills() { return 1; }

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
  _agent_add_install_skills() { return 1; }

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

# ── agent-add integration ─────────────────────────────────────────────────────

@test "_agent_add_install_skills: returns 1 when npx can't be resolved" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  resolve_npx_bin() { return 1; }

  mkdir -p "$STRUT_HOME/.kiro/skills/strut"
  printf -- '---\nname: strut\ndescription: test\n---\n' > "$STRUT_HOME/.kiro/skills/strut/SKILL.md"

  run _agent_add_install_skills "$STRUT_HOME" "kiro" "Kiro"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "_agent_add_install_skills: returns 1 when there are no skills to install" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  resolve_npx_bin() { RESOLVED_NPX_BIN="/fake/npx"; return 0; }
  # No SKILL.md anywhere under $STRUT_HOME/.kiro/skills

  run _agent_add_install_skills "$STRUT_HOME" "kiro" "Kiro"
  [ "$status" -eq 1 ]
}

@test "_agent_add_install_skills: on success, echoes the skill count and passes --skill per skill dir" {
  source "$CLI_ROOT/lib/cmd_skills.sh"

  mkdir -p "$STRUT_HOME/.kiro/skills/strut" "$STRUT_HOME/.kiro/skills/second"
  printf -- '---\nname: strut\ndescription: test\n---\n' > "$STRUT_HOME/.kiro/skills/strut/SKILL.md"
  printf -- '---\nname: second\ndescription: test\n---\n' > "$STRUT_HOME/.kiro/skills/second/SKILL.md"

  local calls_file="$TEST_TMP/npx-calls"
  local fake_npx="$TEST_TMP/fake-npx"
  cat > "$fake_npx" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$calls_file"
exit 0
EOF
  chmod +x "$fake_npx"
  resolve_npx_bin() { RESOLVED_NPX_BIN="$fake_npx"; return 0; }

  # `run` merges stdout+stderr into $output, but callers of this function
  # capture stdout only (`skill_count=$(...)`) — so verify that exact
  # contract via a plain command substitution, not `run`.
  local stdout_only
  stdout_only=$(_agent_add_install_skills "$STRUT_HOME" "kiro" "Kiro" 2>/dev/null)
  [ "$stdout_only" = "2" ]

  run cat "$calls_file"
  [[ "$output" == *"-y agent-add --host kiro"* ]]
  [[ "$output" == *"--skill $STRUT_HOME/.kiro/skills/strut/"* ]]
  [[ "$output" == *"--skill $STRUT_HOME/.kiro/skills/second/"* ]]
}

@test "_agent_add_install_skills: returns 1 and warns on stderr (not swallowed) when agent-add fails" {
  source "$CLI_ROOT/lib/cmd_skills.sh"

  mkdir -p "$STRUT_HOME/.kiro/skills/strut"
  printf -- '---\nname: strut\ndescription: test\n---\n' > "$STRUT_HOME/.kiro/skills/strut/SKILL.md"

  local fake_npx="$TEST_TMP/fake-npx-fail"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_npx"
  chmod +x "$fake_npx"
  resolve_npx_bin() { RESOLVED_NPX_BIN="$fake_npx"; return 0; }

  # stdout must stay clean on failure too — it's what callers capture as the
  # count via `skill_count=$(...)`, so any stray stdout output would corrupt
  # it. Checked separately from stderr since bats `run` merges both streams.
  local stdout_only stderr_only rc
  stdout_only=$(_agent_add_install_skills "$STRUT_HOME" "kiro" "Kiro" 2>/dev/null) && rc=0 || rc=$?
  [ -z "$stdout_only" ]
  [ "$rc" -eq 1 ]

  stderr_only=$(_agent_add_install_skills "$STRUT_HOME" "kiro" "Kiro" 2>&1 1>/dev/null) || true
  [[ "$stderr_only" == *"agent-add install failed"* ]]
}

@test "install kiro: uses agent-add when available, skips the direct-copy fallback" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  local agent_add_called=0
  _agent_add_install_skills() { agent_add_called=1; echo "1"; return 0; }

  mkdir -p "$STRUT_HOME/.kiro/skills/strut"
  printf -- '---\nname: strut\ndescription: test\n---\n' > "$STRUT_HOME/.kiro/skills/strut/SKILL.md"

  run _install_kiro "$STRUT_HOME" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 skill(s)"* ]]
  # The fallback direct-copy never ran — no file was ever placed here by it.
  [ ! -f "$PROJECT_ROOT/.kiro/skills/strut/SKILL.md" ]
}

@test "install claude: uses agent-add when available, skips the direct-copy fallback" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  _agent_add_install_skills() { echo "1"; return 0; }

  mkdir -p "$STRUT_HOME/.kiro/skills/strut"
  printf -- '---\nname: strut\ndescription: test\n---\n' > "$STRUT_HOME/.kiro/skills/strut/SKILL.md"

  run _install_claude "$STRUT_HOME" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/CLAUDE.md" ]
  [ ! -f "$PROJECT_ROOT/.claude/skills/strut/SKILL.md" ]
}

@test "install cursor (_install_rules_file with agent_add_host): success writes steering-only, no inlined skills" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  _agent_add_install_skills() { echo "1"; return 0; }
  _build_skills_content() { echo "SHOULD-NOT-APPEAR-IN-OUTPUT"; }

  run _install_rules_file "$STRUT_HOME" "$PROJECT_ROOT" ".cursorrules" "Cursor" "cursor"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_ROOT/.cursorrules" ]
  run cat "$PROJECT_ROOT/.cursorrules"
  [[ "$output" != *"SHOULD-NOT-APPEAR-IN-OUTPUT"* ]]
}

@test "install cursor (_install_rules_file with agent_add_host): falls back to flattened steering+skills when agent-add fails" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  _agent_add_install_skills() { return 1; }
  _build_skills_content() { echo "SKILLS-CONTENT-MARKER"; }

  run _install_rules_file "$STRUT_HOME" "$PROJECT_ROOT" ".cursorrules" "Cursor" "cursor"
  [ "$status" -eq 0 ]
  run cat "$PROJECT_ROOT/.cursorrules"
  [[ "$output" == *"SKILLS-CONTENT-MARKER"* ]]
}

@test "install zed (_install_rules_file with no agent_add_host): always flattens, never calls agent-add" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  _agent_add_install_skills() { echo "SHOULD-NOT-BE-CALLED"; return 0; }
  _build_skills_content() { echo "SKILLS-CONTENT-MARKER"; }

  run _install_rules_file "$STRUT_HOME" "$PROJECT_ROOT" ".rules" "Zed"
  [ "$status" -eq 0 ]
  run cat "$PROJECT_ROOT/.rules"
  [[ "$output" == *"SKILLS-CONTENT-MARKER"* ]]
}

@test "install copilot: success writes steering-only copilot-instructions.md" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  _agent_add_install_skills() { echo "1"; return 0; }
  _build_skills_content() { echo "SHOULD-NOT-APPEAR-IN-OUTPUT"; }

  run _install_copilot "$STRUT_HOME" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  run cat "$PROJECT_ROOT/.github/copilot-instructions.md"
  [[ "$output" != *"SHOULD-NOT-APPEAR-IN-OUTPUT"* ]]
}

@test "install copilot: falls back to flattened steering+skills when agent-add fails" {
  source "$CLI_ROOT/lib/cmd_skills.sh"
  _agent_add_install_skills() { return 1; }
  _build_skills_content() { echo "SKILLS-CONTENT-MARKER"; }

  run _install_copilot "$STRUT_HOME" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  run cat "$PROJECT_ROOT/.github/copilot-instructions.md"
  [[ "$output" == *"SKILLS-CONTENT-MARKER"* ]]
}
