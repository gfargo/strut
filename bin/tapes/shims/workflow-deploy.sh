# Canned strut output for the workflow-deploy demo (no real execution).
strut() {
  case "$2" in
    deploy)
      sleep 0.4
      printf '→ Connecting to VPS (prod)...\n'
      sleep 0.6
      printf '→ Pulling images: ghcr.io/acme/my-app:latest\n'
      sleep 0.8
      printf '→ Running migrations...\n'
      sleep 0.6
      printf '→ Deploying containers (3/3)...\n'
      sleep 0.6
      printf '  \033[32m✓\033[0m Health check: api       healthy\n'
      sleep 0.2
      printf '  \033[32m✓\033[0m Health check: worker    healthy\n'
      sleep 0.2
      printf '  \033[32m✓\033[0m Health check: postgres  healthy\n'
      sleep 0.4
      printf '\033[1;33m✓ my-app deployed successfully — 12s\033[0m\n' ;;
    *) echo "unknown command: strut $*" ;;
  esac
}
