# workflow-scaffold.tape — Focused scaffold step for the "Three commands" section
# Used for: strut-www homepage workflow tab 02
#
# Story: Show `strut scaffold` generating stack files in one clean beat.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/workflow-scaffold.gif

# ── Hidden setup ──────────────────────────────────────────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/workflow-scaffold.sh" Enter
Type "clear" Enter
Show

# ── Scene: Scaffold ───────────────────────────────────────────────────────────
Sleep 800ms
Type "strut scaffold my-app" Enter
Sleep 2500ms
