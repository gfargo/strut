# Canned strut output for the workflow-init demo (no real execution).
strut() {
  case "$1" in
    init)
      sleep 0.3
      printf '→ Initializing project...\n'
      sleep 0.4
      printf '  \033[32m✓\033[0m Created strut.conf\n'
      sleep 0.25
      printf '  \033[32m✓\033[0m Created stacks/ directory\n'
      sleep 0.25
      printf '  \033[32m✓\033[0m Registry configured: ghcr.io/acme\n'
      sleep 0.3
      printf '\033[1;33m✓ Project initialized\033[0m\n' ;;
    *) echo "unknown command: strut $*" ;;
  esac
}
