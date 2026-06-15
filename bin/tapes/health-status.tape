# health-status.tape — Health check and status overview
# Used for: Marketing still (PNG), README badge area
#
# Story: Quick health check showing all services green.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

# ── Hidden setup ──────────────────────────────────────────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "clear" Enter
Show

# ── Scene: Health check ───────────────────────────────────────────────────────
Sleep 800ms
Type "strut my-app health --env prod"
Sleep 300ms
Enter
Sleep 600ms
Type "printf '\n'"
Enter
Type "printf '  Service          Status     Uptime\n'"
Enter
Type "printf '  ─────────────────────────────────────\n'"
Enter
Type "printf '  \\033[32m●\\033[0m api             healthy    14d 6h\n'"
Enter
Sleep 200ms
Type "printf '  \\033[32m●\\033[0m worker          healthy    14d 6h\n'"
Enter
Sleep 200ms
Type "printf '  \\033[32m●\\033[0m postgres        healthy    14d 6h\n'"
Enter
Sleep 200ms
Type "printf '  \\033[32m●\\033[0m redis           healthy    14d 6h\n'"
Enter
Sleep 200ms
Type "printf '  \\033[32m●\\033[0m nginx           healthy    14d 6h\n'"
Enter
Sleep 400ms
Type "printf '\n  \\033[1;33m✓ 5/5 services healthy\\033[0m\n'"
Enter
Sleep 2000ms

# Capture a still for use as a PNG screenshot
Screenshot ../output/png/health-status.png
