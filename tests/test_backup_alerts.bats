#!/usr/bin/env bats
# ==================================================
# tests/test_backup_alerts.bats — Tests for lib/backup/alerts.sh
# ==================================================
# Covers: alert_backup_failure / alert_verification_failure producing valid
# JSON payloads (even from multi-line messages) and treating a non-2xx
# webhook response as a warned failure, not a hard abort.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/backup/alerts.sh"

  # Stub curl so send_slack_alert/send_email_alert don't hit the network.
  # The JSON payload template itself spans multiple lines in the bash source
  # (insignificant whitespace between tokens — still valid JSON), so we can't
  # just grep a line out of a flattened trace. Capture the exact argument
  # that follows -d instead, byte for byte, into its own file.
  export CURL_PAYLOAD_FILE="$TEST_TMP/curl.payload"
  export CURL_TRACE="$TEST_TMP/curl.trace"
  export CURL_STATUS="${CURL_STATUS:-200}"
  : > "$CURL_TRACE"
  curl() {
    local args=("$@") i
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = "-d" ] && printf '%s' "${args[$((i + 1))]}" > "$CURL_PAYLOAD_FILE"
    done
    printf '%s\n' "${args[@]}" >> "$CURL_TRACE"
    echo "$CURL_STATUS"
    return 0
  }
  export -f curl

  TEST_STACK="test-backup-alerts-$$"
  STACK_DIR="$CLI_ROOT/stacks/$TEST_STACK"
  mkdir -p "$STACK_DIR/backups"

  unset ALERT_EMAIL_TO RESEND_API_KEY
  export SLACK_WEBHOOK_URL="https://hooks.example.com/slack"
}

teardown() {
  rm -rf "$STACK_DIR"
  common_teardown
}

@test "alert_backup_failure: posts a valid JSON payload for a multi-line error message" {
  run alert_backup_failure "$TEST_STACK" "postgres" $'pg_dump exited 1\nsee container logs above'
  [ "$status" -eq 0 ]

  jq empty "$CURL_PAYLOAD_FILE"
  # The user-supplied newline must be escaped (\n, two chars) inside the JSON
  # string value, not left as a raw newline that would corrupt the payload.
  [[ "$(jq -r '.blocks[0].text.text' "$CURL_PAYLOAD_FILE")" == *$'pg_dump exited 1\nsee container logs above'* ]]
  grep -Fq '\n' "$CURL_PAYLOAD_FILE"
}

@test "alert_verification_failure: posts a valid JSON payload" {
  run alert_verification_failure "$TEST_STACK" "$STACK_DIR/backups/postgres-1.sql" $'integrity check failed\nrow count mismatch'
  [ "$status" -eq 0 ]
  jq empty "$CURL_PAYLOAD_FILE"
}

@test "alert_backup_failure: quotes and backslashes in the message don't break the JSON" {
  run alert_backup_failure "$TEST_STACK" "postgres" 'disk "full" at C:\data'
  [ "$status" -eq 0 ]
  jq empty "$CURL_PAYLOAD_FILE"
}

@test "send_backup_alert: non-2xx Slack response is warned, not a hard failure" {
  export CURL_STATUS=500
  run alert_backup_failure "$TEST_STACK" "postgres" "boom"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack alert failed"* ]]
}
