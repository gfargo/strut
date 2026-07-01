# drift-detect.tape — Configuration drift detection
# Story: Detect a mismatch → auto-fix it.
# Output driven by hidden shim (shims/drift-detect.sh).

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/drift-detect.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/drift-detect.sh" Enter
Type "clear" Enter
Show

Sleep 800ms
Type "strut my-app drift detect --env prod" Enter
Sleep 3000ms
Type "strut my-app drift fix --env prod" Enter
Sleep 3000ms
