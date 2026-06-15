# ship.tape — One command to production
# Used for: Hero alternative, "ship it" messaging
#
# Story: Commit, push, and rebuild on remote in one shot.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 30ms
Set WindowBar Colorful

Output ../output/gif/ship.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "clear" Enter
Show

Sleep 600ms
Type "strut my-app ship -m 'fix auth timeout' --env prod"
Sleep 200ms
Enter
Sleep 400ms
Type@0ms "printf '→ Committing changes...\n'"
Enter
Sleep 500ms
Type@0ms "printf '  [main 4a2f1c8] fix auth timeout\n'"
Enter
Sleep 300ms
Type@0ms "printf '→ Pushing to origin/main...\n'"
Enter
Sleep 600ms
Type@0ms "printf '→ Rebuilding on VPS (prod)...\n'"
Enter
Sleep 1000ms
Type@0ms "printf '→ Pulling latest images...\n'"
Enter
Sleep 800ms
Type@0ms "printf '→ Restarting containers...\n'"
Enter
Sleep 600ms
Type@0ms "printf '\\033[1;33m✓ Shipped in 18s\\033[0m\n'"
Enter
Sleep 2500ms
