# backup-restore.tape — Database backup and verification
# Story: Create a backup → verify its integrity.
# Output driven by hidden shim (shims/backup-restore.sh).

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/backup-restore.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/backup-restore.sh" Enter
Type "clear" Enter
Show

Sleep 800ms
Type "strut my-app backup postgres --env prod" Enter
Sleep 3200ms
Type "strut my-app backup verify --env prod" Enter
Sleep 3000ms
