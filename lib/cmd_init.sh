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
  local install_completions="false"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --registry=*) registry_flag="${1#*=}"; shift ;;
      --registry)   registry_flag="$2"; shift 2 ;;
      --org=*)      org_flag="${1#*=}"; shift ;;
      --org)        org_flag="$2"; shift 2 ;;
      --completions) install_completions="true"; shift ;;
      *)            fail "Unknown flag: $1  (usage: strut init [--registry <type>] [--org <name>] [--completions])" ;;
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
      sed -i.bak "s/^# REGISTRY_TYPE=.*/REGISTRY_TYPE=$(sed_escape_replacement "$registry_flag")/" "$PWD/strut.conf"
      rm -f "$PWD/strut.conf.bak"
    else
      echo "REGISTRY_TYPE=$registry_flag" >> "$PWD/strut.conf"
    fi
  fi

  # ── Apply --org flag ──────────────────────────────
  if [ -n "$org_flag" ]; then
    # Validate: only allow Docker-image-safe characters (lowercase, digits, dots, hyphens, underscores)
    if ! [[ "$org_flag" =~ ^[A-Za-z0-9._-]+$ ]]; then
      fail "Invalid --org value: '$org_flag' (must match [A-Za-z0-9._-]+)"
    fi
    # Uncomment and set DEFAULT_ORG (quoted to prevent source injection)
    if grep -q "^# DEFAULT_ORG=" "$PWD/strut.conf"; then
      sed -i.bak "s/^# DEFAULT_ORG=.*/DEFAULT_ORG=\"$(sed_escape_replacement "$org_flag")\"/" "$PWD/strut.conf"
      rm -f "$PWD/strut.conf.bak"
    else
      echo "DEFAULT_ORG=\"$org_flag\"" >> "$PWD/strut.conf"
    fi
  fi

  log "Generated strut.conf"

  # ── Generate/update .gitignore ────────────────────
  # NEVER truncate an existing .gitignore — it is the primary defense against
  # `git clean -fd` deleting untracked data dirs on deploy. Append a marker
  # block with only the rules that are missing.
  # !*.env.age / !*.env.gpg: at-rest encrypted secrets (`secrets lock` /
  # `secrets-filter`) are ciphertext and meant to be committed. They don't
  # end in literally ".env" so .*.env above already misses them — these
  # negations make that explicit and future-proof (strut#178).
  local -a strut_ignores=('.env' '.env.*' '.*.env' '!.env.template' '!*.env.age' '!*.env.gpg' '*.backup-*' 'backups/' 'data/' '.rollback/' '.bluegreen')
  if [ ! -f "$PWD/.gitignore" ]; then
    {
      echo "# strut — generated .gitignore"
      printf '%s\n' "${strut_ignores[@]}"
    } > "$PWD/.gitignore"
    log "Generated .gitignore"
  elif ! grep -qxF "# strut — managed rules" "$PWD/.gitignore"; then
    local added=""
    for rule in "${strut_ignores[@]}"; do
      grep -qxF "$rule" "$PWD/.gitignore" || added+="$rule"$'\n'
    done
    if [ -n "$added" ]; then
      {
        echo ""
        echo "# strut — managed rules"
        printf '%s' "$added"
      } >> "$PWD/.gitignore"
      log "Updated existing .gitignore (appended strut rules)"
    else
      log ".gitignore already covers strut rules — left unchanged"
    fi
  else
    log ".gitignore already has strut-managed rules — left unchanged"
  fi

  # ── Optional: install shell completions ──────────
  if [ "$install_completions" = "true" ]; then
    # shellcheck disable=SC1091
    source "${STRUT_HOME:-$CLI_ROOT}/lib/cmd_completions.sh"
    install_completions
  fi

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
