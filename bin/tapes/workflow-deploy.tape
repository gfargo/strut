# workflow-deploy.tape — Focused deploy step for the "Three commands" section
# Used for: strut-www homepage workflow tab 03
#
# Story: Show `strut deploy` shipping containers to the VPS with health checks.

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/workflow-deploy.gif

# ── Hidden setup ──────────────────────────────────────────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/workflow-deploy.sh" Enter
Type "clear" Enter
Show

# ── Scene: Deploy ─────────────────────────────────────────────────────────────
Sleep 800ms
Type "strut my-app deploy --env prod" Enter
Sleep 4500ms
