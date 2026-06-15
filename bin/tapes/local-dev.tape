# local-dev.tape — Local development workflow
# Used for: Feature section, local dev docs
#
# Story: Start local → sync prod DB → tail logs. The full dev loop.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 30ms
Set WindowBar Colorful

Output ../output/gif/local-dev.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "clear" Enter
Show

# ── Start local ───────────────────────────────────────────────────────────────
Sleep 600ms
Type "strut my-app local start"
Sleep 200ms
Enter
Sleep 400ms
Type@0ms "printf '→ Starting containers (docker compose up -d)...\n'"
Enter
Sleep 800ms
Type@0ms "printf '  ✓ api         running  :3000\n'"
Enter
Sleep 150ms
Type@0ms "printf '  ✓ postgres    running  :5432\n'"
Enter
Sleep 150ms
Type@0ms "printf '  ✓ redis       running  :6379\n'"
Enter
Sleep 300ms
Type@0ms "printf '\\033[1;33m✓ Local stack ready\\033[0m\n'"
Enter
Sleep 1500ms

# ── Sync DB from prod ─────────────────────────────────────────────────────────
Type "strut my-app local sync-db --from prod postgres"
Sleep 200ms
Enter
Sleep 400ms
Type@0ms "printf '→ Pulling latest backup from prod...\n'"
Enter
Sleep 600ms
Type@0ms "printf '→ Restoring into local postgres...\n'"
Enter
Sleep 800ms
Type@0ms "printf '\\033[1;33m✓ Synced 47 tables (24MB)\\033[0m\n'"
Enter
Sleep 1500ms

# ── Tail logs ─────────────────────────────────────────────────────────────────
Type "strut my-app local logs"
Sleep 200ms
Enter
Sleep 400ms
Type@0ms "printf '\\033[90m[api]\\033[0m      Server listening on :3000\n'"
Enter
Sleep 200ms
Type@0ms "printf '\\033[90m[api]\\033[0m      Connected to postgres (47 tables)\n'"
Enter
Sleep 200ms
Type@0ms "printf '\\033[90m[api]\\033[0m      Redis cache warm\n'"
Enter
Sleep 200ms
Type@0ms "printf '\\033[90m[postgres]\\033[0m Ready to accept connections\n'"
Enter
Sleep 1500ms
