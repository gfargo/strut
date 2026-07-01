# Canned strut output for the drift-detect demo.
strut() {
  case "$3" in
    detect)
      printf '→ Comparing local vs remote config...\n'; sleep 1.0
      printf '\033[1;31m✗ Drift detected (2 files)\033[0m\n'; sleep 0.4
      printf '  docker-compose.yml  +2 lines (port mapping added remotely)\n'; sleep 0.3
      printf '  .env.prod           1 var changed (DB_POOL_SIZE: 10→25)\n' ;;
    fix)
      printf '→ Syncing local config to VPS...\n';  sleep 0.8
      printf '  ✓ docker-compose.yml restored\n';   sleep 0.3
      printf '  ✓ .env.prod restored\n';            sleep 0.4
      printf '\033[1;33m✓ Drift resolved — 2 files synced\033[0m\n' ;;
  esac
}
