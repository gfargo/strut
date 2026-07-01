# Canned strut output for the local-dev demo.
strut() {
  case "$3" in
    start)
      printf '→ Starting containers (docker compose up -d)...\n'; sleep 0.8
      printf '  ✓ api         running  :3000\n';       sleep 0.15
      printf '  ✓ postgres    running  :5432\n';       sleep 0.15
      printf '  ✓ redis       running  :6379\n';       sleep 0.3
      printf '\033[1;33m✓ Local stack ready\033[0m\n' ;;
    sync-db)
      printf '→ Pulling latest backup from prod...\n'; sleep 0.6
      printf '→ Restoring into local postgres...\n';   sleep 0.8
      printf '\033[1;33m✓ Synced 47 tables (24MB)\033[0m\n' ;;
    logs)
      printf '\033[90m[api]\033[0m      Server listening on :3000\n';        sleep 0.2
      printf '\033[90m[api]\033[0m      Connected to postgres (47 tables)\n'; sleep 0.2
      printf '\033[90m[api]\033[0m      Redis cache warm\n';                  sleep 0.2
      printf '\033[90m[postgres]\033[0m Ready to accept connections\n' ;;
  esac
}
