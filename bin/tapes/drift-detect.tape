# drift-detect.tape — Configuration drift detection
# Used for: Feature section, drift detection docs
#
# Story: Run drift detection → find a mismatch → auto-fix it.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/drift-detect.gif

# ── Hidden setup ──────────────────────────────────────────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "clear" Enter
Show

# ── Scene: Detect drift ───────────────────────────────────────────────────────
Sleep 800ms
Type "strut my-app drift detect --env prod"
Sleep 300ms
Enter
Sleep 500ms
Type "printf '→ Comparing local vs remote config...\n'"
Enter
Sleep 1000ms
Type "printf '\\033[1;31m✗ Drift detected (2 files)\\033[0m\n'"
Enter
Sleep 400ms
Type "printf '  docker-compose.yml  +2 lines (port mapping added remotely)\n'"
Enter
Sleep 300ms
Type "printf '  .env.prod           1 var changed (DB_POOL_SIZE: 10→25)\n'"
Enter
Sleep 2500ms

# ── Scene: Auto-fix ───────────────────────────────────────────────────────────
Type "strut my-app drift fix --env prod"
Sleep 300ms
Enter
Sleep 400ms
Type "printf '→ Syncing local config to VPS...\n'"
Enter
Sleep 800ms
Type "printf '  ✓ docker-compose.yml restored\n'"
Enter
Sleep 300ms
Type "printf '  ✓ .env.prod restored\n'"
Enter
Sleep 400ms
Type "printf '\\033[1;33m✓ Drift resolved — 2 files synced\\033[0m\n'"
Enter
Sleep 3000ms
