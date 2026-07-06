#!/usr/bin/env bats
# ==================================================
# tests/test_drift_alerts.bats — Tests for lib/drift/alerts.sh
# ==================================================
# Covers: alert_drift_detected producing a valid JSON payload from a
# multi-line files_list, and treating a non-2xx webhook response as a
# warned failure, not a hard abort.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  export RED GREEN YELLOW BLUE NC
  source "$CLI_ROOT/lib/drift/alerts.sh"

  # The JSON payload template spans multiple lines in the bash source
  # (insignificant whitespace between tokens — still valid JSON), so capture
  # the exact argument that follows -d, byte for byte, rather than grepping
  # a flattened trace.
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

  TEST_STACK="test-drift-alerts-$$"
  STACK_DIR="$CLI_ROOT/stacks/$TEST_STACK"
  mkdir -p "$STACK_DIR"

  unset ALERT_EMAIL_TO RESEND_API_KEY
  export SLACK_WEBHOOK_URL="https://hooks.example.com/slack"
}

teardown() {
  rm -rf "$STACK_DIR"
  common_teardown
}

@test "alert_drift_detected: posts a valid JSON payload for a multi-line file list" {
  run alert_drift_detected "$TEST_STACK" "prod" 2 $'docker-compose.yml\n.env.template'
  [ "$status" -eq 0 ]

  jq empty "$CURL_PAYLOAD_FILE"
  grep -Fq '\n' "$CURL_PAYLOAD_FILE"
}

@test "send_drift_alert: non-2xx Slack response is warned, not a hard failure" {
  export CURL_STATUS=500
  run alert_drift_detected "$TEST_STACK" "prod" 1 "docker-compose.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack alert failed"* ]]
}
