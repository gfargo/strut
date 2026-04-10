#!/usr/bin/env bash
# ==================================================
# lib/cmd_init.sh — Initialize a new strut project
# ==================================================
# Requires: lib/utils.sh, lib/config.sh sourced first
#
# Provides:
#   cmd_init [--registry <type>] [--org <name>]

set -euo pipefail

cmd_init() {
  # ── Parse flags ───────────────────────────────────
  local registry_flag=""
  local org_flag=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --registry=*) registry_flag="${1#*=}"; shift ;;
      --registry)   registry_flag="$2"; shift 2 ;;
      --org=*)      org_flag="${1#*=}"; shift ;;
      --org)        org_flag="$2"; shift 2 ;;
      *)            fail "Unknown flag: $1  (usage: strut init [--registry <type>] [--org <name>])" ;;
    esac
  done

  # ── Guard: already initialized ────────────────────
  if [ -f "$PWD/strut.conf" ]; then
    fail "Project already initialized (strut.conf exists in $PWD)"
  fi

  local templates_dir="${STRUT_HOME:-$CLI_ROOT}/templates"
  [ -d "$templates_dir" ] || fail "templates/ directory not found in STRUT_HOME"

  # ── Create stacks/ directory ──────────────────────
  mkdir -p "$PWD/stacks"
  log "Created stacks/ directory"

  # ── Generate strut.conf from template ─────────────
  if [ -f "$templates_dir/strut.conf.template" ]; then
    cp "$templates_dir/strut.conf.template" "$PWD/strut.conf"
  else
    # Fallback: generate minimal strut.conf
    cat > "$PWD/strut.conf" <<'EOF'
# strut.conf — Project-level configuration
# REGISTRY_TYPE=none
# DEFAULT_BRANCH=main
# BANNER_TEXT=strut
EOF
  fi

  # ── Apply --registry flag ─────────────────────────
  if [ -n "$registry_flag" ]; then
    # Validate registry type
    case "$registry_flag" in
      ghcr|dockerhub|ecr|none) ;;
      *) fail "Unsupported registry type: $registry_flag (supported: ghcr, dockerhub, ecr, none)" ;;
    esac
    # Uncomment and set REGISTRY_TYPE
    if grep -q "^# REGISTRY_TYPE=" "$PWD/strut.conf"; then
      sed -i.bak "s/^# REGISTRY_TYPE=.*/REGISTRY_TYPE=$registry_flag/" "$PWD/strut.conf"
      rm -f "$PWD/strut.conf.bak"
    else
      echo "REGISTRY_TYPE=$registry_flag" >> "$PWD/strut.conf"
    fi
  fi

  # ── Apply --org flag ──────────────────────────────
  if [ -n "$org_flag" ]; then
    # Uncomment and set DEFAULT_ORG
    if grep -q "^# DEFAULT_ORG=" "$PWD/strut.conf"; then
      sed -i.bak "s/^# DEFAULT_ORG=.*/DEFAULT_ORG=$org_flag/" "$PWD/strut.conf"
      rm -f "$PWD/strut.conf.bak"
    else
      echo "DEFAULT_ORG=$org_flag" >> "$PWD/strut.conf"
    fi
  fi

  log "Generated strut.conf"

  # ── Generate .gitignore ───────────────────────────
  cat > "$PWD/.gitignore" <<'GITIGNORE_EOF'
# strut — generated .gitignore
.env
.env.*
!.env.template
backups/
data/
GITIGNORE_EOF
  log "Generated .gitignore"

  # ── Next steps ────────────────────────────────────
  echo ""
  ok "Project initialized in $PWD"
  echo ""
  echo "Next steps:"
  echo "  1. strut scaffold <stack-name>    Create your first stack"
  echo "  2. Edit stacks/<name>/.env.template and fill in your secrets"
  echo "  3. strut <stack> deploy --env prod"
  echo ""
}
