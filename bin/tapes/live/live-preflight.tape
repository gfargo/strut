# live-preflight.tape — REAL strut doctor --deep against a real VPS.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 30ms
Set WindowBar Colorful
Set Width 1400
Set Height 800

Output ../output/gif/live-preflight.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "bash live/shims/pre-record.sh" Enter
Sleep 6s
Type "clear" Enter
Sleep 500ms
Show

Sleep 800ms
Type "strut doctor --deep" Enter
Sleep 10000ms
