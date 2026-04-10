#!/usr/bin/env bash
# ==================================================
# lib/cmd_skills.sh — Install AI agent context for strut projects
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Provides:
#   cmd_skills <subcommand>
#
# Two types of content:
#   Steering  — always-on context (conventions, architecture, config patterns)
#   Skills    — on-demand procedures (deploy, debug, backup, etc.)
#
# Supported tools:
#   kiro, claude, cursor, windsurf, zed, copilot, cline, agents, generic

set -euo pipefail

cmd_skills() {
  local subcmd="${1:-}"

  case "$subcmd" in
    install)  _skills_install "${@:2}" ;;
    list)     _skills_list ;;
    ""|help)  _skills_usage ;;
    *)        _skills_usage; fail "Unknown skills subcommand: $subcmd" ;;
  esac
}

_skills_install() {
  local format="kiro"
  local target=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --format=*) format="${1#*=}"; shift ;;
      --format)   format="$2"; shift 2 ;;
      *)          target="$1"; shift ;;
    esac
  done

  local strut_home="${STRUT_HOME:-$CLI_ROOT}"
  local skills_src="$strut_home/.kiro/skills"
  local steering_src="$strut_home/.kiro/steering"
  local project_root="${PROJECT_ROOT:-$PWD}"

  [ -d "$skills_src" ] || fail "Skills not found at $skills_src"

  case "$format" in
    kiro)     _install_kiro "$strut_home" "$project_root" ;;
    claude)   _install_claude "$strut_home" "$project_root" ;;
    cursor)   _install_rules_file "$strut_home" "$project_root" ".cursorrules" "Cursor" ;;
    windsurf) _install_rules_file "$strut_home" "$project_root" ".windsurfrules" "Windsurf" ;;
    zed)      _install_rules_file "$strut_home" "$project_root" ".rules" "Zed" ;;
    cline)    _install_rules_file "$strut_home" "$project_root" ".clinerules" "Cline" ;;
    copilot)  _install_copilot "$strut_home" "$project_root" ;;
    agents)   _install_rules_file "$strut_home" "$project_root" "AGENTS.md" "AGENTS.md-compatible tools" ;;
    generic)  _install_generic "$strut_home" "$project_root" ;;
    all)      _install_all "$strut_home" "$project_root" ;;
    *)        fail "Unknown format: $format (run 'strut skills help' for supported formats)" ;;
  esac
}

# ── Helpers: build steering and skills content ────────────────────────────────

# Build the steering block (conventions, architecture, always-on context)
_build_steering_content() {
  local strut_home="$1"
  local steering_dir="$strut_home/.kiro/steering"
  local claude_md="$strut_home/CLAUDE.md"

  # Start with CLAUDE.md if it exists (it's the canonical developer context)
  if [ -f "$claude_md" ]; then
    cat "$claude_md"
  else
    echo "# strut — VPS Stack Management CLI"
    echo ""
    echo "Bash CLI tool for managing Docker stacks on VPS infrastructure."
  fi

  # Append steering files
  if [ -d "$steering_dir" ]; then
    for steering_file in "$steering_dir"/*.md; do
      [ -f "$steering_file" ] || continue
      echo ""
      echo "---"
      echo ""
      # Strip YAML frontmatter
      awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2||fm==0{print}' "$steering_file"
    done
  fi
}

# Build the skills block (on-demand procedures)
_build_skills_content() {
  local strut_home="$1"
  local skills_dir="$strut_home/.kiro/skills"

  echo "## Operational Procedures"
  echo ""
  echo "Reference procedures for common strut operations."

  for skill_dir in "$skills_dir"/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_file="$skill_dir/SKILL.md"
    [ -f "$skill_file" ] || continue

    echo ""
    echo "---"
    echo ""
    # Strip YAML frontmatter
    awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2||fm==0{print}' "$skill_file"
  done
}

# ── Kiro: native format ───────────────────────────────────────────────────────
# Steering → .kiro/steering/
# Skills   → .kiro/skills/
_install_kiro() {
  local strut_home="$1"
  local project_root="$2"

  # Install skills
  local skills_target="$project_root/.kiro/skills/strut"
  if [ -d "$skills_target" ]; then
    rm -rf "$skills_target"
  fi
  mkdir -p "$(dirname "$skills_target")"
  cp -r "$strut_home/.kiro/skills" "$skills_target"
  rm -f "$skills_target/.DS_Store" "$skills_target/README.md" 2>/dev/null || true

  local skill_count
  skill_count=$(find "$skills_target" -name "SKILL.md" | wc -l | tr -d ' ')

  # Install steering
  local steering_count=0
  if [ -d "$strut_home/.kiro/steering" ]; then
    local steering_target="$project_root/.kiro/steering"
    mkdir -p "$steering_target"
    for f in "$strut_home/.kiro/steering"/*.md; do
      [ -f "$f" ] || continue
      local basename
      basename=$(basename "$f")
      # Prefix with strut- to avoid conflicts with user's own steering
      cp "$f" "$steering_target/strut-$basename"
      steering_count=$((steering_count + 1))
    done
  fi

  ok "Kiro: $skill_count skills → .kiro/skills/strut/"
  ok "Kiro: $steering_count steering docs → .kiro/steering/strut-*.md"
}

# ── Claude Code: CLAUDE.md + .claude/commands/ ────────────────────────────────
# Steering → CLAUDE.md (always loaded)
# Skills   → .claude/commands/<name>.md (invoked as /name)
_install_claude() {
  local strut_home="$1"
  local project_root="$2"

  # Steering → CLAUDE.md
  local claude_file="$project_root/CLAUDE.md"
  _build_steering_content "$strut_home" > "$claude_file"
  ok "Claude: steering → CLAUDE.md"

  # Skills → .claude/commands/strut-<name>.md
  local commands_dir="$project_root/.claude/commands"
  mkdir -p "$commands_dir"

  local skill_count=0
  for skill_dir in "$strut_home/.kiro/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_file="$skill_dir/SKILL.md"
    [ -f "$skill_file" ] || continue

    local name
    name=$(basename "$skill_dir")
    local cmd_file="$commands_dir/strut-$name.md"

    # Strip frontmatter for the command file
    awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2||fm==0{print}' "$skill_file" > "$cmd_file"
    skill_count=$((skill_count + 1))
  done

  ok "Claude: $skill_count skills → .claude/commands/strut-*.md"
  echo "  Invoke with: /strut-vps-deployment, /strut-database-backups, etc."
}

# ── Copilot: .github/copilot-instructions.md ──────────────────────────────────
# Steering → .github/copilot-instructions.md (always loaded)
# Skills   → appended to same file (no separate invocation mechanism)
_install_copilot() {
  local strut_home="$1"
  local project_root="$2"

  local target="$project_root/.github/copilot-instructions.md"
  mkdir -p "$(dirname "$target")"

  {
    _build_steering_content "$strut_home"
    echo ""
    echo "---"
    echo ""
    _build_skills_content "$strut_home"
  } > "$target"

  ok "Copilot: steering + skills → .github/copilot-instructions.md"
}

# ── Single rules file (Cursor, Windsurf, Zed, Cline, AGENTS.md) ──────────────
# Steering → top of file (always loaded)
# Skills   → appended below (always available as reference)
_install_rules_file() {
  local strut_home="$1"
  local project_root="$2"
  local filename="$3"
  local tool_name="$4"

  local target="$project_root/$filename"

  {
    _build_steering_content "$strut_home"
    echo ""
    echo "---"
    echo ""
    _build_skills_content "$strut_home"
  } > "$target"

  ok "$tool_name: steering + skills → $filename"
}

# ── Generic: docs/ directory ──────────────────────────────────────────────────
# Steering → docs/strut-context.md
# Skills   → docs/strut-skills.md
_install_generic() {
  local strut_home="$1"
  local project_root="$2"

  mkdir -p "$project_root/docs"

  _build_steering_content "$strut_home" > "$project_root/docs/strut-context.md"
  ok "Generic: steering → docs/strut-context.md"

  {
    echo "# strut Operational Procedures"
    echo ""
    _build_skills_content "$strut_home"
  } > "$project_root/docs/strut-skills.md"
  ok "Generic: skills → docs/strut-skills.md"
}

# ── All formats ───────────────────────────────────────────────────────────────
_install_all() {
  local strut_home="$1"
  local project_root="$2"

  echo ""
  log "Installing all AI context formats..."
  echo ""

  _install_kiro "$strut_home" "$project_root"
  _install_claude "$strut_home" "$project_root"
  _install_rules_file "$strut_home" "$project_root" ".cursorrules" "Cursor"
  _install_rules_file "$strut_home" "$project_root" ".windsurfrules" "Windsurf"
  _install_rules_file "$strut_home" "$project_root" ".rules" "Zed"
  _install_rules_file "$strut_home" "$project_root" ".clinerules" "Cline"
  _install_copilot "$strut_home" "$project_root"
  _install_rules_file "$strut_home" "$project_root" "AGENTS.md" "Generic agents"

  echo ""
  ok "All formats installed"
}

# ── List ──────────────────────────────────────────────────────────────────────
_skills_list() {
  local strut_home="${STRUT_HOME:-$CLI_ROOT}"
  local skills_dir="$strut_home/.kiro/skills"
  local steering_dir="$strut_home/.kiro/steering"

  echo ""
  echo -e "${BLUE}Steering (always-on context):${NC}"
  echo ""
  if [ -d "$steering_dir" ]; then
    for f in "$steering_dir"/*.md; do
      [ -f "$f" ] || continue
      local name
      name=$(basename "$f" .md)
      echo -e "  ${GREEN}✓${NC} $name"
    done
  else
    echo "  (none)"
  fi

  echo ""
  echo -e "${BLUE}Skills (on-demand procedures):${NC}"
  echo ""

  if [ ! -d "$skills_dir" ]; then
    echo "  (none)"
    return 0
  fi

  for skill_dir in "$skills_dir"/*/; do
    [ -d "$skill_dir" ] || continue
    local name
    name=$(basename "$skill_dir")
    local skill_file="$skill_dir/SKILL.md"
    if [ -f "$skill_file" ]; then
      local desc
      desc=$(sed -n '/^description:/s/^description: *//p' "$skill_file" | head -1)
      if [ -n "$desc" ]; then
        if [ ${#desc} -gt 65 ]; then
          desc="${desc:0:62}..."
        fi
        echo -e "  ${GREEN}✓${NC} $name"
        echo "    $desc"
      else
        echo -e "  ${GREEN}✓${NC} $name"
      fi
    fi
  done
  echo ""
}

# ── Usage ─────────────────────────────────────────────────────────────────────
_skills_usage() {
  echo ""
  echo "Usage: strut skills <command> [options]"
  echo ""
  echo "Commands:"
  echo "  list                          List available steering docs and skills"
  echo "  install [--format <fmt>]      Install AI context for your editor/tool"
  echo ""
  echo "Formats:"
  echo "  kiro      Kiro IDE [default]"
  echo "              steering → .kiro/steering/strut-*.md"
  echo "              skills   → .kiro/skills/strut/"
  echo "  claude    Claude Code / Claude Desktop"
  echo "              steering → CLAUDE.md"
  echo "              skills   → .claude/commands/strut-*.md (as /slash commands)"
  echo "  cursor    Cursor"
  echo "              steering + skills → .cursorrules"
  echo "  windsurf  Windsurf"
  echo "              steering + skills → .windsurfrules"
  echo "  zed       Zed (also reads .cursorrules, CLAUDE.md)"
  echo "              steering + skills → .rules"
  echo "  copilot   GitHub Copilot"
  echo "              steering + skills → .github/copilot-instructions.md"
  echo "  cline     Cline"
  echo "              steering + skills → .clinerules"
  echo "  agents    Generic agent convention"
  echo "              steering + skills → AGENTS.md"
  echo "  generic   Any tool (separate files)"
  echo "              steering → docs/strut-context.md"
  echo "              skills   → docs/strut-skills.md"
  echo "  all       Generate all formats at once"
  echo ""
  echo "Examples:"
  echo "  strut skills list"
  echo "  strut skills install                        # Kiro (default)"
  echo "  strut skills install --format claude        # Claude Code"
  echo "  strut skills install --format cursor        # Cursor"
  echo "  strut skills install --format copilot       # GitHub Copilot"
  echo "  strut skills install --format all           # Everything"
  echo ""
}
