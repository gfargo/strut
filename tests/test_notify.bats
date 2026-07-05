#!/usr/bin/env bats
# ==================================================
# tests/test_notify.bats — Tests for notification dispatcher
# ==================================================

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/notify.sh"

  # Stub curl so provider send functions don't hit the network.
  # Providers now capture curl's stdout as the HTTP status code (-w
  # '%{http_code}' -o /dev/null), so the stub must print one. Each argument is
  # traced on its own line (not space-joined) so a test can grep out the exact
  # JSON payload argument and pipe it to `jq empty` — a payload with a stray
  # literal newline embedded in it would corrupt this one-arg-per-line trace,
  # which is exactly the bug this suite guards against.
  export CURL_TRACE="$TEST_TMP/curl.trace"
  export CURL_STATUS="${CURL_STATUS:-200}"
  : > "$CURL_TRACE"
  curl() {
    local arg
    for arg in "$@"; do printf '%s\n' "$arg" >> "$CURL_TRACE"; done
    echo "$CURL_STATUS"
    return 0
  }
  export -f curl

  # Reset config-loaded flag and provider envs for each test
  unset NOTIFY_CONFIG_LOADED
  unset SLACK_WEBHOOK SLACK_EVENTS
  unset DISCORD_WEBHOOK DISCORD_EVENTS
  unset WEBHOOK_URL WEBHOOK_EVENTS
  NOTIFY_CONFIG_LOADED=false
}

teardown() {
  common_teardown
}

# ---------- _notify_provider_subscribed ----------

@test "_notify_provider_subscribed: exact event match returns 0" {
  run _notify_provider_subscribed "deploy.success,deploy.fail" "deploy.success"
  [ "$status" -eq 0 ]
}

@test "_notify_provider_subscribed: non-matching event returns 1" {
  run _notify_provider_subscribed "deploy.success" "backup.success"
  [ "$status" -eq 1 ]
}

@test "_notify_provider_subscribed: wildcard matches any event" {
  run _notify_provider_subscribed "*" "anything.at.all"
  [ "$status" -eq 0 ]
}

@test "_notify_provider_subscribed: wildcard in CSV list matches" {
  run _notify_provider_subscribed "deploy.fail,*" "random.event"
  [ "$status" -eq 0 ]
}

@test "_notify_provider_subscribed: empty list returns 1" {
  run _notify_provider_subscribed "" "deploy.success"
  [ "$status" -eq 1 ]
}

@test "_notify_provider_subscribed: tolerates whitespace around entries" {
  run _notify_provider_subscribed "deploy.success, deploy.fail , backup.success" "deploy.fail"
  [ "$status" -eq 0 ]
}

# ---------- notify_load_config ----------

@test "notify_load_config: loads variables from config file" {
  cat > "$TEST_TMP/notifications.conf" <<'EOF'
SLACK_WEBHOOK=https://hooks.example.com/slack
SLACK_EVENTS=deploy.success
EOF
  notify_load_config "$TEST_TMP/notifications.conf"
  [ "$SLACK_WEBHOOK" = "https://hooks.example.com/slack" ]
  [ "$SLACK_EVENTS" = "deploy.success" ]
}

@test "notify_load_config: is idempotent — second call is a no-op" {
  cat > "$TEST_TMP/notifications.conf" <<'EOF'
SLACK_WEBHOOK=first-value
EOF
  notify_load_config "$TEST_TMP/notifications.conf"
  [ "$SLACK_WEBHOOK" = "first-value" ]

  # Rewrite the file — should NOT be re-read
  cat > "$TEST_TMP/notifications.conf" <<'EOF'
SLACK_WEBHOOK=second-value
EOF
  notify_load_config "$TEST_TMP/notifications.conf"
  [ "$SLACK_WEBHOOK" = "first-value" ]
}

@test "notify_load_config: missing file is non-fatal" {
  run notify_load_config "/nonexistent/path/notifications.conf"
  [ "$status" -eq 0 ]
}

# ---------- notify_event ----------

@test "notify_event: dry-run echoes event and returns 0" {
  export DRY_RUN=true
  run notify_event deploy.success stack=my-stack env=prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"[notify:dry-run]"* ]]
  [[ "$output" == *"event=deploy.success"* ]]
  [[ "$output" == *"stack=my-stack"* ]]
}

@test "notify_event: no providers configured — returns 0 silently" {
  export DRY_RUN=false
  run notify_event deploy.success stack=my-stack
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notify_event: only dispatches to subscribed providers" {
  export DRY_RUN=false
  export SLACK_WEBHOOK=https://hooks.example.com/slack
  export SLACK_EVENTS=deploy.success
  export DISCORD_WEBHOOK=https://discord.example.com/hook
  export DISCORD_EVENTS=backup.success
  NOTIFY_CONFIG_LOADED=true

  run notify_event deploy.success stack=my-stack
  [ "$status" -eq 0 ]
  local trace
  trace=$(cat "$CURL_TRACE")
  [[ "$trace" == *"hooks.example.com/slack"* ]]
  [[ "$trace" != *"discord.example.com"* ]]
}

@test "notify_event: wildcard provider receives all events" {
  export DRY_RUN=false
  export WEBHOOK_URL=https://ops.example.com/strut
  export WEBHOOK_EVENTS="*"
  NOTIFY_CONFIG_LOADED=true

  run notify_event custom.event key=value
  [ "$status" -eq 0 ]
  grep -q "ops.example.com/strut" "$CURL_TRACE"
}

@test "notify_event: always returns 0 even when provider send fails" {
  export DRY_RUN=false
  export SLACK_WEBHOOK=https://hooks.example.com/slack
  export SLACK_EVENTS="*"
  NOTIFY_CONFIG_LOADED=true
  # Force send function to fail
  notify_slack_send() { return 1; }
  export -f notify_slack_send

  run notify_event deploy.success stack=x
  [ "$status" -eq 0 ]
}

# ---------- _notify_payload_json ----------

@test "_notify_payload_json: builds JSON with event key" {
  run _notify_payload_json deploy.success
  [ "$status" -eq 0 ]
  [ "$output" = '{"event":"deploy.success"}' ]
}

@test "_notify_payload_json: appends key=value pairs" {
  run _notify_payload_json deploy.success stack=my-stack env=prod
  [ "$status" -eq 0 ]
  [ "$output" = '{"event":"deploy.success","stack":"my-stack","env":"prod"}' ]
}

@test "_notify_payload_json: escapes double quotes in values" {
  run _notify_payload_json some.event msg='hello "world"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'\"world\"'* ]]
}

@test "_notify_payload_json: escapes backslashes in values" {
  run _notify_payload_json some.event path='a\b\c'
  [ "$status" -eq 0 ]
  # Each `\` becomes `\\` (JSON-escaped); input has 3 → output has 6 backslashes
  [[ "$output" == *'a\\b\\c'* ]]
}

@test "_notify_payload_json: multi-line/quoted/backslash values stay valid JSON" {
  run _notify_payload_json some.event msg=$'line one\nline "two"\nback\\slash'
  [ "$status" -eq 0 ]
  echo "$output" | jq empty
}

# ---------- slack/discord/webhook: valid JSON + HTTP status handling ----------

@test "notify_slack_send: multi-line values produce a single-line, valid JSON payload" {
  run notify_slack_send "https://hooks.example.com/slack" deploy.fail msg=$'line one\nline two'
  [ "$status" -eq 0 ]
  local payload
  payload=$(grep '^{' "$CURL_TRACE")
  [ "$(echo "$payload" | wc -l)" -eq 1 ]
  echo "$payload" | jq empty
  [[ "$payload" == *'line one\nline two'* ]]
}

@test "notify_slack_send: returns 0 on 2xx response" {
  export CURL_STATUS=204
  run notify_slack_send "https://hooks.example.com/slack" deploy.success msg=hi
  [ "$status" -eq 0 ]
}

@test "notify_slack_send: returns 1 and warns on non-2xx response" {
  export CURL_STATUS=500
  run notify_slack_send "https://hooks.example.com/slack" deploy.success msg=hi
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 500"* ]]
}

@test "notify_discord_send: returns 1 on non-2xx response" {
  export CURL_STATUS=404
  run notify_discord_send "https://discord.example.com/hook" deploy.success msg=hi
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 404"* ]]
}

@test "notify_webhook_send: returns 1 on non-2xx response" {
  export CURL_STATUS=503
  run notify_webhook_send "https://ops.example.com/strut" deploy.success msg=hi
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 503"* ]]
}

@test "notify_event: non-2xx provider response is only warned, event dispatch still returns 0" {
  export DRY_RUN=false
  export CURL_STATUS=500
  export SLACK_WEBHOOK=https://hooks.example.com/slack
  export SLACK_EVENTS="*"
  NOTIFY_CONFIG_LOADED=true

  run notify_event deploy.success stack=x
  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack notification failed"* ]]
}

# ---------- notify_test ----------

@test "notify_test: empty provider name fails with usage" {
  run notify_test ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "notify_test: unknown provider fails" {
  run notify_test bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown provider"* ]]
}

@test "notify_test: slack without SLACK_WEBHOOK configured fails" {
  NOTIFY_CONFIG_LOADED=true
  run notify_test slack
  [ "$status" -ne 0 ]
  [[ "$output" == *"SLACK_WEBHOOK not configured"* ]]
}

@test "notify_test: slack with webhook configured sends test ping" {
  export SLACK_WEBHOOK=https://hooks.example.com/slack
  NOTIFY_CONFIG_LOADED=true
  run notify_test slack
  [ "$status" -eq 0 ]
  grep -q "hooks.example.com/slack" "$CURL_TRACE"
}
