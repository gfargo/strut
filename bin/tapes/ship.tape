# ship.tape — One command to production
# Story: Commit, push, and rebuild on remote in one shot.
# Output driven by hidden shim (shims/ship.sh) — no real infra, no stray errors.

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
Type "source shims/ship.sh" Enter
Type "clear" Enter
Show

Sleep 600ms
Type `strut my-app ship -m 'fix auth timeout' --env prod`
Enter
Sleep 5000ms
