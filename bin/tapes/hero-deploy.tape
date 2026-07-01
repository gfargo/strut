# hero-deploy.tape — The headline workflow: init → scaffold → deploy
# Used for: README hero GIF, marketing site header
#
# Story: Show the full "zero to deployed" flow in one tight scene.
#
# Output is driven by a hidden strut() shim (shims/hero-deploy.sh) so the
# recording shows clean, deterministic output — no real infra, no stray errors.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/hero-deploy.gif

# ── Hidden setup: prompt + strut output shim ──────────────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/hero-deploy.sh" Enter
Type "clear" Enter
Show

# ── Scene: Init → Scaffold → Deploy ───────────────────────────────────────────
Sleep 800ms
Type "strut init --registry ghcr --org acme" Enter
Sleep 2000ms
Type "strut scaffold my-app" Enter
Sleep 2000ms
Type "strut my-app release --env prod" Enter
Sleep 3000ms
