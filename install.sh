#!/usr/bin/env bash
# ==================================================
# install.sh — Install or upgrade strut
# ==================================================
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<org>/strut/main/install.sh | bash
#
# Environment variables:
#   STRUT_HOME    — Installation directory (default: ~/.strut)
#   STRUT_REPO    — Git repository URL (default: https://github.com/<org>/strut.git)
#   STRUT_BRANCH  — Branch to install from (default: main)
#
# Supports macOS and Linux.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
STRUT_HOME="${STRUT_HOME:-$HOME/.strut}"
STRUT_REPO="${STRUT_REPO:-}"
STRUT_BRANCH="${STRUT_BRANCH:-main}"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[strut]${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# ── Preflight checks ─────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || fail "git is required but not installed"

# ── Install or upgrade ────────────────────────────────────────────────────────
if [ -d "$STRUT_HOME/.git" ]; then
  log "Existing installation found at $STRUT_HOME — upgrading..."
  git -C "$STRUT_HOME" fetch origin "$STRUT_BRANCH" --quiet
  git -C "$STRUT_HOME" reset --hard "origin/$STRUT_BRANCH" --quiet
else
  if [ -z "$STRUT_REPO" ]; then
    fail "STRUT_REPO must be set (e.g., https://github.com/your-org/strut.git)"
  fi
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
  # Hint if ~/.local/bin is not in PATH
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
VERSION_FILE="$STRUT_HOME/VERSION"
if [ -f "$VERSION_FILE" ]; then
  ok "strut $(cat "$VERSION_FILE") installed"
else
  ok "strut installed (version unknown)"
fi
