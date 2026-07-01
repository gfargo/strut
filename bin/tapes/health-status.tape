# health-status.tape — Health check overview (still PNG)
# Story: Quick health check showing all services green.
# Output driven by hidden shim (shims/health-status.sh).

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/health-status.sh" Enter
Type "clear" Enter
Show

Sleep 800ms
Type "strut my-app health --env prod" Enter
Sleep 2500ms
Screenshot ../output/png/health-status.png
