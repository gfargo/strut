# local-dev.tape — Local development workflow
# Story: Start local → sync prod DB → tail logs.
# Output driven by hidden shim (shims/local-dev.sh).

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
Type "source shims/local-dev.sh" Enter
Type "clear" Enter
Show

Sleep 600ms
Type "strut my-app local start" Enter
Sleep 2200ms
Type "strut my-app local sync-db --from prod postgres" Enter
Sleep 2200ms
Type "strut my-app local logs" Enter
Sleep 2500ms
