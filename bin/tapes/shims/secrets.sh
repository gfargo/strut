# Canned strut output for the secrets-lifecycle demo.
strut() {
  case "$3" in
    validate)
      printf '→ Validating .prod.env against required_vars...\n'; sleep 0.6
      printf '  ✓ 12 required vars present\n';                     sleep 0.15
      printf '  ✓ no placeholders or weak secrets\n';             sleep 0.15
      printf '  ✓ no unresolved provider refs\n';                 sleep 0.2
      printf '\033[1;33m✓ Secrets valid\033[0m\n' ;;
    push)
      printf '→ Validating .prod.env...\n';                       sleep 0.5
      printf '→ Uploading to my-app@prod (scp, chmod 0600)...\n'; sleep 0.8
      printf '\033[1;33m✓ Secrets pushed to prod\033[0m\n' ;;
    lock)
      printf '→ Encrypting .prod.env with age...\n';              sleep 0.7
      printf '  ✓ .prod.env.age written (1 recipient)\n';         sleep 0.3
      printf '  ✓ plaintext .prod.env removed\n';                 sleep 0.2
      printf '\033[1;33m✓ Locked — safe to commit\033[0m\n' ;;
  esac
}
