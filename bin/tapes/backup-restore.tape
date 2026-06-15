# backup-restore.tape — Database backup and restore workflow
# Used for: Feature section, docs illustration
#
# Story: Show reliable backup creation and verification in one beat.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/backup-restore.gif

# ── Hidden setup ──────────────────────────────────────────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "clear" Enter
Show

# ── Scene: Backup ─────────────────────────────────────────────────────────────
Sleep 800ms
Type "strut my-app backup postgres --env prod"
Sleep 300ms
Enter
Sleep 500ms
Type "printf '→ Connecting to VPS (prod)...\n'"
Enter
Sleep 600ms
Type "printf '→ Dumping postgres (my-app-db)...\n'"
Enter
Sleep 1200ms
Type "printf '✓ Backup: my-app-postgres-20260614-120000.sql.gz (24MB)\n'"
Enter
Sleep 400ms
Type "printf '✓ Uploaded to offsite: s3://backups/my-app/\n'"
Enter
Sleep 2500ms

# ── Scene: Verify ─────────────────────────────────────────────────────────────
Type "strut my-app backup verify --env prod"
Sleep 300ms
Enter
Sleep 400ms
Type "printf '→ Verifying latest backup integrity...\n'"
Enter
Sleep 800ms
Type "printf '  ✓ Checksum: valid\n  ✓ Tables: 47/47 present\n  ✓ Row counts: within 1%% of live\n'"
Enter
Sleep 400ms
Type "printf '\\033[1;33m✓ Backup verified\\033[0m\n'"
Enter
Sleep 3000ms
