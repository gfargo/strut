# live-deploy.tape — REAL container up-and-teardown against a real VPS.
# Uses strut exec (over SSH) to spin an nginx smoke container on port 18081,
# curl it from the runner, then remove it. Idempotent — safe to re-record.

Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 30ms
Set WindowBar Colorful
Set Width 1400
Set Height 750

Output ../output/gif/live-deploy.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "bash live/shims/pre-record.sh" Enter
Sleep 6s
Type "clear" Enter
Sleep 500ms
Show

Sleep 800ms
Type `strut probe exec 'docker run -d --name live-demo-nginx -p 18081:80 nginx:alpine' --env prod` Enter
Sleep 6000ms
Type `curl -sf -o /dev/null -w "GET :18081 -> HTTP %{http_code}\n" http://${STRUT_LIVE_HOST}:18081/` Enter
Sleep 2500ms
Type `strut probe exec 'docker rm -f live-demo-nginx' --env prod` Enter
Sleep 3500ms
