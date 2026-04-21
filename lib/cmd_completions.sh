#!/usr/bin/env bash
# ==================================================
# lib/cmd_completions.sh — emit/install shell completion scripts
# ==================================================
#
# `strut completions <shell>` prints the completion script for the target
# shell (bash|zsh|fish) to stdout, ready to be eval'd or saved to the
# shell's completions directory.
#
# `strut init --completions` auto-detects the user's shell (from $SHELL)
# and installs the right script to a conventional location.

set -euo pipefail

cmd_completions() {
  local shell="${1:-}"
  local script_path

  case "$shell" in
    bash) script_path="$STRUT_HOME/completions/bash.sh" ;;
    zsh)  script_path="$STRUT_HOME/completions/zsh.sh" ;;
    fish) script_path="$STRUT_HOME/completions/fish.fish" ;;
    ""|--help|-h)
      echo "Usage: strut completions <bash|zsh|fish>"
      echo ""
      echo "Prints the completion script for your shell. Suggested install:"
      echo ""
      echo "  # bash"
      echo "  echo 'eval \"\$(strut completions bash)\"' >> ~/.bashrc"
      echo ""
      echo "  # zsh"
      echo "  echo 'eval \"\$(strut completions zsh)\"' >> ~/.zshrc"
      echo ""
      echo "  # fish"
      echo "  strut completions fish > ~/.config/fish/completions/strut.fish"
      echo ""
      echo "Or run \`strut init --completions\` to auto-install for your current shell."
      [ -z "$shell" ] && exit 1 || exit 0
      ;;
    *)
      fail "Unknown shell: '$shell' (valid: bash, zsh, fish)"
      ;;
  esac

  [ -f "$script_path" ] || fail "Completion script not found: $script_path"
  cat "$script_path"
}

# install_completions — called by `strut init --completions`. Detects shell
# from $SHELL and installs into the conventional location for that shell.
# Idempotent: appends an eval line (bash/zsh) or writes the full script
# (fish) only if the target is missing the strut hook.
install_completions() {
  local detected="${SHELL##*/}"
  case "$detected" in
    bash)
      local rc="${HOME}/.bashrc"
      # shellcheck disable=SC2016 # literal eval expression, stored verbatim in rc file
      local line='eval "$(strut completions bash)"'
      if grep -Fq "$line" "$rc" 2>/dev/null; then
        log "bash completions already installed in $rc"
      else
        printf '\n# strut completions\n%s\n' "$line" >> "$rc"
        ok "Installed bash completions (open a new shell or run: source $rc)"
      fi
      ;;
    zsh)
      local rc="${HOME}/.zshrc"
      # shellcheck disable=SC2016 # literal eval expression, stored verbatim in rc file
      local line='eval "$(strut completions zsh)"'
      if grep -Fq "$line" "$rc" 2>/dev/null; then
        log "zsh completions already installed in $rc"
      else
        printf '\n# strut completions\n%s\n' "$line" >> "$rc"
        ok "Installed zsh completions (open a new shell or run: source $rc)"
      fi
      ;;
    fish)
      local dir="${HOME}/.config/fish/completions"
      mkdir -p "$dir"
      cat "$STRUT_HOME/completions/fish.fish" > "$dir/strut.fish"
      ok "Installed fish completions to $dir/strut.fish"
      ;;
    *)
      warn "Unrecognized shell '$detected' — run 'strut completions <bash|zsh|fish>' manually"
      return 1
      ;;
  esac
}
