# rollback.tape — Instant recovery from a bad deploy
# Used for: Safety messaging, "what if it breaks?" section
#
# Story: Deploy goes wrong → health check fails → rollback → instant recovery.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 30ms
Set WindowBar Colorful

Output ../output/gif/rollback.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "clear" Enter
Show

# ── Failed deploy ─────────────────────────────────────────────────────────────
Sleep 600ms
Type "strut my-app health --env prod"
Sleep 200ms
Enter
Sleep 500ms
Type@0ms "printf '  \\033[32m●\\033[0m postgres   healthy\n'"
Enter
Sleep 150ms
Type@0ms "printf '  \\033[32m●\\033[0m redis      healthy\n'"
Enter
Sleep 150ms
Type@0ms "printf '  \\033[31m●\\033[0m api        unhealthy (502)\n'"
Enter
Sleep 300ms
Type@0ms "printf '\\033[1;31m✗ 1/3 services failing\\033[0m\n'"
Enter
Sleep 2000ms

# ── Rollback ──────────────────────────────────────────────────────────────────
Type "strut my-app rollback --env prod"
Sleep 200ms
Enter
Sleep 400ms
Type@0ms "printf '→ Rolling back to previous release (v2.3.1)...\n'"
Enter
Sleep 800ms
Type@0ms "printf '→ Restoring containers...\n'"
Enter
Sleep 600ms
Type@0ms "printf '→ Health check: 3/3 healthy\n'"
Enter
Sleep 300ms
Type@0ms "printf '\\033[1;33m✓ Rolled back in 4s\\033[0m\n'"
Enter
Sleep 2500ms
