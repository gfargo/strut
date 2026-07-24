# Canned strut output for the workflow-scaffold demo (no real execution).
strut() {
  case "$1" in
    scaffold)
      sleep 0.3
      printf '→ Scaffolding stack: my-app\n'
      sleep 0.4
      printf '  \033[32m✓\033[0m stacks/my-app/docker-compose.yml\n'
      sleep 0.2
      printf '  \033[32m✓\033[0m stacks/my-app/services.conf\n'
      sleep 0.2
      printf '  \033[32m✓\033[0m stacks/my-app/.env.template\n'
      sleep 0.2
      printf '  \033[32m✓\033[0m stacks/my-app/Dockerfile\n'
      sleep 0.3
      printf '\033[1;33m✓ Stack scaffolded — edit .env and deploy\033[0m\n' ;;
    *) echo "unknown command: strut $*" ;;
  esac
}
