# rollback.tape — Instant recovery from a bad deploy
# Story: Health check fails → rollback → instant recovery.
# Output driven by hidden shim (shims/rollback.sh).

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 30ms
Set WindowBar Colorful

Output ../output/gif/rollback.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/rollback.sh" Enter
Type "clear" Enter
Show

Sleep 600ms
Type "strut my-app health --env prod" Enter
Sleep 2500ms
Type "strut my-app rollback --env prod" Enter
Sleep 3000ms
