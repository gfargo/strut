# workflow-init.tape — Focused init step for the "Three commands" section
# Used for: strut-www homepage workflow tab 01
#
# Story: Show `strut init` creating the project scaffold in one clean beat.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/workflow-init.gif

# ── Hidden setup ──────────────────────────────────────────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/workflow-init.sh" Enter
Type "clear" Enter
Show

# ── Scene: Init ───────────────────────────────────────────────────────────────
Sleep 800ms
Type "strut init --registry ghcr --org acme" Enter
Sleep 2500ms
