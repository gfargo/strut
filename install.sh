#!/usr/bin/env bash
# ==================================================
# install.sh — Install, upgrade, or uninstall strut
# ==================================================
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/gfargo/strut/main/install.sh | bash
#
# Upgrade:
#   curl -fsSL https://raw.githubusercontent.com/gfargo/strut/main/install.sh | bash
#   (or just: strut upgrade)
#
# Uninstall:
#   curl -fsSL https://raw.githubusercontent.com/gfargo/strut/main/install.sh | bash -s -- --uninstall
#
# Environment variables:
#   STRUT_HOME    — Installation directory (default: ~/.strut)
#   STRUT_REPO    — Git repository URL (default: https://github.com/gfargo/strut.git)
#   STRUT_BRANCH  — Branch to install from (default: main)
#
# Supports macOS and Linux.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
STRUT_HOME="${STRUT_HOME:-$HOME/.strut}"
STRUT_REPO="${STRUT_REPO:-https://github.com/gfargo/strut.git}"
STRUT_BRANCH="${STRUT_BRANCH:-main}"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[strut]${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC}  $1"; }
fail() { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# ── Parse flags ───────────────────────────────────────────────────────────────
UNINSTALL=false
SKIP_SKILLS=false
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
    --no-skills) SKIP_SKILLS=true ;;
  esac
done

# ── Uninstall ─────────────────────────────────────────────────────────────────
if $UNINSTALL; then
  log "Uninstalling strut..."
  rm -f /usr/local/bin/strut "$HOME/.local/bin/strut" 2>/dev/null || true
  if [ -d "$STRUT_HOME" ]; then
    rm -rf "$STRUT_HOME"
    ok "Removed $STRUT_HOME"
  fi
  ok "strut uninstalled"
  exit 0
fi

# ── Preflight checks ─────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || fail "git is required but not installed"

# ── Install or upgrade ────────────────────────────────────────────────────────
OLD_VERSION=""
if [ -d "$STRUT_HOME/.git" ]; then
  # Capture current version before upgrade
  if [ -f "$STRUT_HOME/VERSION" ]; then
    OLD_VERSION=$(cat "$STRUT_HOME/VERSION" | tr -d '[:space:]')
  fi

  log "Existing installation found at $STRUT_HOME — upgrading..."
  git -C "$STRUT_HOME" fetch origin "$STRUT_BRANCH" --quiet
  git -C "$STRUT_HOME" reset --hard "origin/$STRUT_BRANCH" --quiet
else
  log "Installing strut to $STRUT_HOME..."
  git clone --branch "$STRUT_BRANCH" --single-branch --quiet "$STRUT_REPO" "$STRUT_HOME"
fi

chmod +x "$STRUT_HOME/strut"

# ── Symlink to PATH ──────────────────────────────────────────────────────────
_create_symlink() {
  local target="$STRUT_HOME/strut"
  local link_dir="$1"
  local link_path="$link_dir/strut"

  mkdir -p "$link_dir"
  if [ -L "$link_path" ] || [ -e "$link_path" ]; then
    rm -f "$link_path"
  fi
  ln -s "$target" "$link_path"
  ok "Symlinked strut → $link_path"
}

if [ -w "/usr/local/bin" ]; then
  _create_symlink "/usr/local/bin"
else
  _create_symlink "$HOME/.local/bin"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
      echo ""
      echo "  Add ~/.local/bin to your PATH:"
      echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
      echo ""
      ;;
  esac
fi

# ── Print version ─────────────────────────────────────────────────────────────
NEW_VERSION=""
if [ -f "$STRUT_HOME/VERSION" ]; then
  NEW_VERSION=$(cat "$STRUT_HOME/VERSION" | tr -d '[:space:]')
fi

if [ -n "$OLD_VERSION" ] && [ -n "$NEW_VERSION" ]; then
  if [ "$OLD_VERSION" = "$NEW_VERSION" ]; then
    ok "strut $NEW_VERSION (already up to date)"
  else
    ok "strut upgraded: $OLD_VERSION → $NEW_VERSION"
  fi
elif [ -n "$NEW_VERSION" ]; then
  ok "strut $NEW_VERSION installed"
else
  ok "strut installed (version unknown)"
fi

# ── Provision Kiro skills to user project ─────────────────────────────────────
if ! $SKIP_SKILLS; then
  echo ""
  log "Kiro skills available in $STRUT_HOME/.kiro/skills/"
  echo ""
  echo "  To use strut skills in your project, copy them to your workspace:"
  echo ""
  echo "    cp -r $STRUT_HOME/.kiro/skills/ <your-project>/.kiro/skills/strut/"
  echo ""
  echo "  Or symlink them (auto-updates with strut upgrade):"
  echo ""
  echo "    mkdir -p <your-project>/.kiro/skills"
  echo "    ln -s $STRUT_HOME/.kiro/skills <your-project>/.kiro/skills/strut"
  echo ""
fi

# ── Next steps (fresh install only) ──────────────────────────────────────────
if [ -z "$OLD_VERSION" ]; then
  echo "Get started:"
  echo "  strut init --registry ghcr --org my-org"
  echo "  strut scaffold my-app"
  echo "  strut --help"
  echo ""
fi
