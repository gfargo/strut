# hero-deploy.tape — The headline workflow: init → scaffold → deploy
# Used for: README hero GIF, marketing site header
#
# Story: Show the full "zero to deployed" flow in one tight scene.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/hero-deploy.gif

# ── Hidden setup ──────────────────────────────────────────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "clear" Enter
Show

# ── Scene: Init ───────────────────────────────────────────────────────────────
Sleep 800ms
Type "strut init --registry ghcr --org acme"
Sleep 300ms
Enter
Sleep 400ms
Type "printf '✓ Created strut.conf\n✓ Created stacks/ directory\n✓ Registry: ghcr.io/acme\n'"
Enter
Sleep 2000ms

# ── Scene: Scaffold ───────────────────────────────────────────────────────────
Type "strut scaffold my-app"
Sleep 300ms
Enter
Sleep 400ms
Type "printf '✓ stacks/my-app/docker-compose.yml\n✓ stacks/my-app/services.conf\n✓ stacks/my-app/.env.template\n'"
Enter
Sleep 2000ms

# ── Scene: Deploy ─────────────────────────────────────────────────────────────
Type "strut my-app release --env prod"
Sleep 300ms
Enter
Sleep 500ms
Type "printf '→ Syncing repository on VPS...\n'"
Enter
Sleep 600ms
Type "printf '→ Running migrations...\n'"
Enter
Sleep 800ms
Type "printf '→ Deploying containers...\n'"
Enter
Sleep 600ms
Type "printf '\\033[1;33m✓ my-app deployed successfully\\033[0m\n'"
Enter
Sleep 400ms
Type "printf '→ Health check: 3/3 services healthy\n'"
Enter
Sleep 300ms
Type "printf '\\033[1;33m✓ Done in 12s\\033[0m\n'"
Enter
Sleep 3000ms
