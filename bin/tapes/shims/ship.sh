# Canned strut output for the ship demo.
strut() {
  case "$2" in
    ship)
      printf '→ Committing changes...\n';            sleep 0.5
      printf '  [main 4a2f1c8] fix auth timeout\n';   sleep 0.3
      printf '→ Pushing to origin/main...\n';         sleep 0.6
      printf '→ Rebuilding on VPS (prod)...\n';       sleep 1.0
      printf '→ Pulling latest images...\n';          sleep 0.8
      printf '→ Restarting containers...\n';          sleep 0.6
      printf '\033[1;33m✓ Shipped in 18s\033[0m\n' ;;
  esac
}
