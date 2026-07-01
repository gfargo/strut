# Canned strut output for the backup-restore demo.
strut() {
  case "$3" in
    postgres)
      printf '→ Connecting to VPS (prod)...\n';        sleep 0.6
      printf '→ Dumping postgres (my-app-db)...\n';     sleep 1.2
      printf '✓ Backup: my-app-postgres-20260614-120000.sql.gz (24MB)\n'; sleep 0.4
      printf '✓ Uploaded to offsite: s3://backups/my-app/\n' ;;
    verify)
      printf '→ Verifying latest backup integrity...\n'; sleep 0.8
      printf '  ✓ Checksum: valid\n'
      printf '  ✓ Tables: 47/47 present\n'
      printf '  ✓ Row counts: within 1%% of live\n';    sleep 0.4
      printf '\033[1;33m✓ Backup verified\033[0m\n' ;;
  esac
}
