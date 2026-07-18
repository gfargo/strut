#!/usr/bin/env bats
# ==================================================
# tests/test_briefing.bats — lib/briefing.sh + lib/cmd_briefing.sh
# ==================================================
# Run:  bats tests/test_briefing.bats
# Covers: severity ranking/posture, per-dimension normalizers (exit-code +
# guarded jq parsing), error isolation (one failing check -> unknown, siblings
# still reported), JSON shape, and posture-driven exit codes.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/briefing.sh"
  source "$CLI_ROOT/lib/cmd_briefing.sh"

  export TEST_TMP="$(mktemp -d)"
  _make_fake_strut
  # Point the check runner at the fake binary instead of the real strut.
  export STRUT_HOME="$TEST_TMP"
  export CMD_STACK=demo CMD_ENV_NAME=prod CMD_JSON=--json
}

teardown() {
  rm -rf "$TEST_TMP"
}

# A fake `strut` that returns canned stdout/rc per subcommand from files the
# test drops in $TEST_TMP (<key>.out / <key>.rc). Absent files -> empty/0.
_make_fake_strut() {
  local d="$TEST_TMP"
  cat > "$d/strut" <<EOF
#!/usr/bin/env bash
shift  # drop stack
case "\$1 \${2:-}" in
  "health"*)       key=health ;;
  "drift detect")  key=drift_detect ;;
  "drift images")  key=drift_images ;;
  "diff"*)         key=diff ;;
  "backup health") key=backup_health ;;
  *)               key=unknown ;;
esac
[ -f "$d/\$key.out" ] && cat "$d/\$key.out"
if [ -f "$d/\$key.rc" ]; then exit "\$(cat "$d/\$key.rc")"; fi
exit 0
EOF
  chmod +x "$d/strut"
}

# _resp <key> <stdout> <rc>
_resp() {
  printf '%s' "$2" > "$TEST_TMP/$1.out"
  printf '%s' "$3" > "$TEST_TMP/$1.rc"
}

# All-healthy baseline; individual tests override single dimensions.
_baseline_healthy() {
  _resp health        '{"overall_status":"healthy","checks":[{"name":"Container: web","status":"pass"}]}' 0
  _resp drift_detect  'in sync' 0
  _resp drift_images  '{"stack":"demo","total":2,"drifted":0,"images":[]}' 0
  _resp diff          '{"has_changes":false,"has_destructive_changes":false}' 0
  _resp backup_health '[{"status":"healthy","health_score":95}]' 0
}

# ── Severity ranking / posture ────────────────────────────────────────────────

@test "worst: higher-ranked severity wins" {
  [ "$(_briefing_worst ok warn)" = "warn" ]
  [ "$(_briefing_worst critical warn)" = "critical" ]
  [ "$(_briefing_worst ok unknown)" = "ok" ]
  [ "$(_briefing_worst unknown unknown)" = "unknown" ]
}

@test "posture: worst-wins across dimensions" {
  [ "$(_briefing_posture ok ok warn ok)" = "warn" ]
  [ "$(_briefing_posture ok warn critical)" = "critical" ]
}

@test "posture: all-unknown collapses to unknown" {
  [ "$(_briefing_posture unknown unknown unknown)" = "unknown" ]
}

@test "posture: unknown never dominates a real ok" {
  [ "$(_briefing_posture ok unknown unknown)" = "ok" ]
}

# ── health normalizer ─────────────────────────────────────────────────────────

@test "norm_health: healthy json -> ok with container count" {
  run _briefing_norm_health '{"overall_status":"healthy","checks":[{"name":"Container: web","status":"pass"}]}' 0
  [[ "$output" == ok$'\t'* ]]
  [[ "$output" == *"1/1 containers healthy"* ]]
}

@test "norm_health: degraded json -> warn" {
  run _briefing_norm_health '{"overall_status":"degraded","checks":[{"name":"Container: db","status":"fail"}]}' 1
  [[ "$output" == warn$'\t'* ]]
}

@test "norm_health: unhealthy json -> critical" {
  run _briefing_norm_health '{"overall_status":"unhealthy","checks":[]}' 2
  [[ "$output" == critical$'\t'* ]]
}

@test "norm_health: no json falls back to rc" {
  run _briefing_norm_health '' 2
  [[ "$output" == critical$'\t'* ]]
  run _briefing_norm_health '' 0
  [[ "$output" == ok$'\t'* ]]
}

@test "norm_health: timeout (rc 124) -> unknown" {
  run _briefing_norm_health '' 124
  [[ "$output" == unknown$'\t'* ]]
}

# ── drift normalizer ──────────────────────────────────────────────────────────

@test "norm_drift: rc 0 -> ok" {
  run _briefing_norm_drift 'no drift' 0
  [[ "$output" == ok$'\t'* ]]
}

@test "norm_drift: non-zero with stdout -> critical (drift)" {
  run _briefing_norm_drift 'docker-compose.yml differs' 1
  [[ "$output" == critical$'\t'* ]]
}

@test "norm_drift: non-zero with empty stdout -> unknown (couldn't run)" {
  run _briefing_norm_drift '' 1
  [[ "$output" == unknown$'\t'* ]]
}

# ── images normalizer ─────────────────────────────────────────────────────────

@test "norm_images: drifted>0 -> warn" {
  run _briefing_norm_images '{"total":3,"drifted":1,"images":[]}' 1
  [[ "$output" == warn$'\t'* ]]
  [[ "$output" == *"1/3"* ]]
}

@test "norm_images: drifted 0 -> ok" {
  run _briefing_norm_images '{"total":2,"drifted":0,"images":[]}' 0
  [[ "$output" == ok$'\t'* ]]
}

@test "norm_images: no json -> unknown" {
  run _briefing_norm_images 'No running containers for demo' 0
  [[ "$output" == unknown$'\t'* ]]
}

# ── diff normalizer ───────────────────────────────────────────────────────────

@test "norm_diff: no changes -> ok (false must not be read as empty)" {
  run _briefing_norm_diff '{"has_changes":false,"has_destructive_changes":false}' 0
  [[ "$output" == ok$'\t'* ]]
}

@test "norm_diff: pending changes -> warn" {
  run _briefing_norm_diff '{"has_changes":true,"has_destructive_changes":false}' 1
  [[ "$output" == warn$'\t'* ]]
}

@test "norm_diff: destructive changes -> critical" {
  run _briefing_norm_diff '{"has_changes":true,"has_destructive_changes":true}' 1
  [[ "$output" == critical$'\t'* ]]
}

@test "norm_diff: hard error (rc 2, no json) -> unknown" {
  run _briefing_norm_diff '' 2
  [[ "$output" == unknown$'\t'* ]]
}

# ── backup normalizer ─────────────────────────────────────────────────────────

@test "norm_backup: strips leading log line, all healthy -> ok" {
  run _briefing_norm_backup '✓ Dashboard data generated: /x
[{"status":"healthy","health_score":95}]' 0
  [[ "$output" == ok$'\t'* ]]
}

@test "norm_backup: worst engine status wins (one degraded -> critical)" {
  run _briefing_norm_backup '[{"status":"healthy"},{"status":"degraded"}]' 0
  [[ "$output" == critical$'\t'* ]]
}

@test "norm_backup: warning -> warn" {
  run _briefing_norm_backup '[{"status":"warning"}]' 0
  [[ "$output" == warn$'\t'* ]]
}

@test "norm_backup: empty array -> unknown" {
  run _briefing_norm_backup '[]' 0
  [[ "$output" == unknown$'\t'* ]]
}

# ── Full cmd_briefing flow ────────────────────────────────────────────────────

@test "briefing: all-healthy -> posture ok, exit 0, no actions" {
  _baseline_healthy
  run cmd_briefing
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.posture == "ok"'
  echo "$output" | jq -e '.actions | length == 0'
  echo "$output" | jq -e '.dimensions | length == 5'
}

@test "briefing: JSON is well-formed with all documented keys" {
  _baseline_healthy
  run cmd_briefing
  echo "$output" | jq -e 'has("stack") and has("env") and has("generated_at") and has("posture") and has("dimensions") and has("actions")'
  echo "$output" | jq -e '.stack == "demo" and .env == "prod"'
}

@test "briefing: worst dimension drives posture; exit non-zero" {
  _baseline_healthy
  _resp drift_detect 'docker-compose.yml differs' 1   # critical
  run cmd_briefing
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.posture == "critical"'
}

@test "briefing: actions are ordered worst-first with remediation commands" {
  _baseline_healthy
  _resp drift_detect 'differs' 1                                        # critical
  _resp drift_images '{"total":3,"drifted":1,"images":[]}' 1            # warn
  run cmd_briefing
  # First action is the critical one; each carries a command.
  echo "$output" | jq -e '.actions[0].severity == "critical"'
  echo "$output" | jq -e '[.actions[].command | startswith("strut demo ")] | all'
}

@test "briefing: one failing check degrades to unknown, siblings still reported" {
  _baseline_healthy
  # diff hard-fails (rc 3, no output). It must NOT abort the whole briefing;
  # it degrades to unknown while every sibling is still reported. Posture stays
  # ok (unknown never dominates a real ok), so this exercises isolation, not
  # the exit code.
  _resp diff '' 3
  run cmd_briefing
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.dimensions | length == 5'
  echo "$output" | jq -e '.dimensions[] | select(.name=="diff") | .severity == "unknown"'
  # A sibling that was healthy is still ok.
  echo "$output" | jq -e '.dimensions[] | select(.name=="health") | .severity == "ok"'
  # unknown ranks below ok, so it is not surfaced as a remediation action.
  echo "$output" | jq -e '.actions | length == 0'
}

@test "briefing: unknown dimensions never get a remediation action" {
  _baseline_healthy
  _resp drift_detect '' 1                     # unknown (couldn't run)
  _resp drift_images 'no containers' 0        # unknown (no json)
  run cmd_briefing
  echo "$output" | jq -e '[.actions[].dimension] | (index("drift") | not) and (index("images") | not)'
}

@test "briefing: text mode renders a posture line and per-dimension rows" {
  _baseline_healthy
  export CMD_JSON=""   # human output
  run cmd_briefing
  [[ "$output" == *"Briefing: demo (prod)"* ]]
  [[ "$output" == *"Posture:"* ]]
  [[ "$output" == *"health"* ]]
  [[ "$output" == *"backups"* ]]
}

@test "briefing: --help prints usage and exits 0" {
  run cmd_briefing --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: strut <stack> briefing"* ]]
}
