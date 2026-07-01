# Canned strut output for the health-status still.
strut() {
  case "$2" in
    health)
      printf '\n'
      printf '  Service          Status     Uptime\n'
      printf '  ─────────────────────────────────────\n'
      printf '  \033[32m●\033[0m api             healthy    14d 6h\n'; sleep 0.2
      printf '  \033[32m●\033[0m worker          healthy    14d 6h\n'; sleep 0.2
      printf '  \033[32m●\033[0m postgres        healthy    14d 6h\n'; sleep 0.2
      printf '  \033[32m●\033[0m redis           healthy    14d 6h\n'; sleep 0.2
      printf '  \033[32m●\033[0m nginx           healthy    14d 6h\n'; sleep 0.4
      printf '\n  \033[1;33m✓ 5/5 services healthy\033[0m\n' ;;
  esac
}
