# secrets.tape — The secrets lifecycle: validate → push → lock
# Story: validate before shipping, push to the VPS, encrypt at rest.
# Output driven by hidden shim (shims/secrets.sh).

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 30ms
Set WindowBar Colorful

Output ../output/gif/secrets.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/secrets.sh" Enter
Type "clear" Enter
Show

Sleep 600ms
Type "strut my-app secrets validate --env prod" Enter
Sleep 2600ms
Type "strut my-app secrets push --env prod" Enter
Sleep 2400ms
Type "strut my-app secrets lock --env prod" Enter
Sleep 3000ms
