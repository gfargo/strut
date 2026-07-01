# Canned strut output for the rollback demo.
strut() {
  case "$2" in
    health)
      printf '  \033[32m●\033[0m postgres   healthy\n';         sleep 0.15
      printf '  \033[32m●\033[0m redis      healthy\n';         sleep 0.15
      printf '  \033[31m●\033[0m api        unhealthy (502)\n'; sleep 0.3
      printf '\033[1;31m✗ 1/3 services failing\033[0m\n' ;;
    rollback)
      printf '→ Rolling back to previous release (v2.3.1)...\n'; sleep 0.8
      printf '→ Restoring containers...\n';                      sleep 0.6
      printf '→ Health check: 3/3 healthy\n';                    sleep 0.3
      printf '\033[1;33m✓ Rolled back in 4s\033[0m\n' ;;
  esac
}
