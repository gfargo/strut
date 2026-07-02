#!/usr/bin/env bash
# ==================================================
# lib/cmd_upgrade.sh — Install-method-aware upgrade
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Provides:
#   strut_install_method  — echoes "git" | "brew" | "unknown"
#   cmd_upgrade           — upgrades strut via the correct method

set -euo pipefail

_usage_upgrade() {
  echo ""
  echo "Usage: strut upgrade"
  echo ""
  echo "Upgrade strut to the latest version."
  echo ""
  echo "Upgrade behaviour depends on how strut was installed:"
  echo "  git   — runs 'git pull' inside STRUT_HOME"
  echo "  brew  — runs 'brew upgrade gfargo/tap/strut'"
  echo "  other — prints the re-install one-liner"
  echo ""
  echo "Flags:"
  echo "  --help   Show this help"
  echo ""
  echo "Examples:"
  echo "  strut upgrade"
  echo ""
}

# strut_install_method
# Detect whether strut is installed via git clone, Homebrew, or some other
# method.  Echoes one of: git | brew | unknown
strut_install_method() {
  local strut_home="${STRUT_HOME:-}"

  # git-clone install: STRUT_HOME contains a .git directory
  if [ -d "${strut_home}/.git" ]; then
    echo "git"
    return 0
  fi

  # Homebrew install: path contains /Cellar/ (typical resolved libexec path)
  # or brew is available and lists strut as installed
  if [[ "$strut_home" == */Cellar/* ]]; then
    echo "brew"
    return 0
  fi

  if command -v brew > /dev/null 2>&1; then
    if brew list gfargo/tap/strut > /dev/null 2>&1; then
      echo "brew"
      return 0
    fi
  fi

  echo "unknown"
}

# cmd_upgrade
# Upgrade strut using the detected install method.
cmd_upgrade() {
  # Parse flags
  for _arg in "$@"; do
    case "$_arg" in
      --help|-h) _usage_upgrade; return 0 ;;
    esac
  done

  local method
  method="$(strut_install_method)"

  case "$method" in
    git)
      local branch="${DEFAULT_BRANCH:-main}"
      log "Upgrading strut (git) from origin/$branch..."
      git -C "$STRUT_HOME" pull origin "$branch"
      local version_file="$STRUT_HOME/VERSION"
      if [ -f "$version_file" ]; then
        ok "strut upgraded to $(cat "$version_file")"
      else
        ok "strut upgraded (version unknown)"
      fi
      ;;

    brew)
      log "Upgrading strut via Homebrew..."
      if command -v brew > /dev/null 2>&1; then
        brew upgrade gfargo/tap/strut || {
          warn "brew upgrade failed. Try running manually:"
          echo "  brew upgrade gfargo/tap/strut"
          return 1
        }
        local version_file="$STRUT_HOME/VERSION"
        if [ -f "$version_file" ]; then
          ok "strut upgraded to $(cat "$version_file")"
        else
          ok "strut upgraded via Homebrew"
        fi
      else
        warn "Homebrew not found in PATH. To upgrade strut, run:"
        echo "  brew upgrade gfargo/tap/strut"
        return 1
      fi
      ;;

    unknown)
      warn "Cannot determine install method for STRUT_HOME=$STRUT_HOME"
      echo ""
      echo "To upgrade strut, re-run the installer:"
      echo "  curl -fsSL https://raw.githubusercontent.com/gfargo/strut/main/install.sh | bash"
      echo ""
      echo "Or, for a manual git-clone install:"
      echo "  git -C ~/.strut pull origin main"
      echo ""
      ;;
  esac
}
