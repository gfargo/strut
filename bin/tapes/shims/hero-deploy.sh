# Canned strut output for the hero-deploy demo (no real execution).
strut() {
  case "$1" in
    init)
      printf '\033[32m✓\033[0m Created strut.conf\n'
      printf '\033[32m✓\033[0m Created stacks/ directory\n'
      printf '\033[32m✓\033[0m Registry: ghcr.io/acme\n' ;;
    scaffold)
      printf '\033[32m✓\033[0m stacks/my-app/docker-compose.yml\n'
      printf '\033[32m✓\033[0m stacks/my-app/services.conf\n'
      printf '\033[32m✓\033[0m stacks/my-app/.env.template\n' ;;
    *)
      case "$2" in
        release)
          printf '→ Syncing repository on VPS...\n';      sleep 0.6
          printf '→ Running migrations...\n';              sleep 0.8
          printf '→ Deploying containers...\n';            sleep 0.6
          printf '\033[1;33m✓ my-app deployed successfully\033[0m\n'; sleep 0.4
          printf '→ Health check: 3/3 services healthy\n'; sleep 0.3
          printf '\033[1;33m✓ Done in 12s\033[0m\n' ;;
      esac ;;
  esac
}
