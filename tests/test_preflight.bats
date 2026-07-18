#!/usr/bin/env bats
# ==================================================
# tests/test_preflight.bats — lib/cmd_preflight.sh
# ==================================================
# Run:  bats tests/test_preflight.bats
# Covers: the GO / CAUTION / NO-GO verdict matrix, the 0/1/2 exit-code mapping,
# and that reasons carry a recommended command while checks echoes every
# evaluated dimension.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/briefing.sh"
  source "$CLI_ROOT/lib/cmd_preflight.sh"

  export TEST_TMP="$(mktemp -d)"
  _make_fake_strut
  export STRUT_HOME="$TEST_TMP"
  export CMD_STACK=demo CMD_ENV_NAME=prod CMD_JSON=--json
}

teardown() {
  rm -rf "$TEST_TMP"
}

_make_fake_strut() {
  local d="$TEST_TMP"
  cat > "$d/strut" <<EOF
#!/usr/bin/env bash
shift  # drop stack
case "\$1 \${2:-}" in
  "health"*)       key=health ;;
  "drift detect")  key=drift_detect ;;
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

# Clean, deployable baseline: healthy, in sync, pending non-destructive
# changes, fresh backups. Individual tests override one dimension.
_baseline_deployable() {
  _resp health        '{"overall_status":"healthy","checks":[{"name":"Container: web","status":"pass"}]}' 0
  _resp drift_detect  'in sync' 0
  _resp diff          '{"has_changes":true,"has_destructive_changes":false}' 1
  _resp backup_health '[{"status":"healthy","health_score":95}]' 0
}

# ── GO ────────────────────────────────────────────────────────────────────────

@test "preflight: clean + pending changes -> GO, exit 0" {
  _baseline_deployable
  run cmd_preflight
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "GO"'
}

@test "preflight: no pending changes is informational, still GO" {
  _baseline_deployable
  _resp diff '{"has_changes":false,"has_destructive_changes":false}' 0
  run cmd_preflight
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "GO"'
  echo "$output" | jq -e '[.reasons[].message] | any(. == "No pending changes to deploy")'
}

# ── NO-GO ─────────────────────────────────────────────────────────────────────

@test "preflight: config drift -> NO-GO, exit 2" {
  _baseline_deployable
  _resp drift_detect 'docker-compose.yml differs on VPS' 1
  run cmd_preflight
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.verdict == "NO-GO"'
  echo "$output" | jq -e '[.reasons[] | select(.severity=="critical")] | length >= 1'
}

@test "preflight: diff+drift both unavailable -> NO-GO (blind), exit 2" {
  _baseline_deployable
  _resp diff '' 2          # unknown (no remote target)
  _resp drift_detect '' 1  # unknown (empty stdout)
  run cmd_preflight
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.verdict == "NO-GO"'
  echo "$output" | jq -e '[.reasons[].message] | any(startswith("Cannot assess deploy safety"))'
}

@test "preflight: drift NO-GO overrides a co-occurring caution" {
  _baseline_deployable
  _resp drift_detect 'differs' 1                    # NO-GO
  _resp backup_health '[{"status":"degraded"}]' 0   # would be CAUTION alone
  run cmd_preflight
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.verdict == "NO-GO"'
}

# ── CAUTION ───────────────────────────────────────────────────────────────────

@test "preflight: unhealthy stack -> CAUTION, exit 1" {
  _baseline_deployable
  _resp health '{"overall_status":"unhealthy","checks":[]}' 2
  run cmd_preflight
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.verdict == "CAUTION"'
}

@test "preflight: destructive pending changes -> CAUTION, exit 1" {
  _baseline_deployable
  _resp diff '{"has_changes":true,"has_destructive_changes":true}' 1
  run cmd_preflight
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.verdict == "CAUTION"'
}

@test "preflight: stale/failing backups -> CAUTION, exit 1" {
  _baseline_deployable
  _resp backup_health '[{"status":"degraded","health_score":40}]' 0
  run cmd_preflight
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.verdict == "CAUTION"'
}

@test "preflight: degraded health stays GO but is surfaced as an info reason" {
  _baseline_deployable
  _resp diff '{"has_changes":false,"has_destructive_changes":false}' 0  # no diff noise
  _resp health '{"overall_status":"degraded","checks":[{"name":"Container: web","status":"pass"}]}' 1
  run cmd_preflight
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.verdict == "GO"'
  echo "$output" | jq -e '[.reasons[] | select(.severity=="info") | .message] | any(startswith("Stack is degraded"))'
}

# ── Structure ─────────────────────────────────────────────────────────────────

@test "preflight: checks echoes every evaluated dimension" {
  _baseline_deployable
  run cmd_preflight
  echo "$output" | jq -e '.checks | has("diff") and has("drift") and has("health") and has("backups")'
}

@test "preflight: every reason carries a recommended command" {
  _baseline_deployable
  _resp drift_detect 'differs' 1
  run cmd_preflight
  echo "$output" | jq -e '[.reasons[].command | startswith("strut demo ")] | all'
}

@test "preflight: JSON has all documented top-level keys" {
  _baseline_deployable
  run cmd_preflight
  echo "$output" | jq -e 'has("stack") and has("env") and has("generated_at") and has("verdict") and has("checks") and has("reasons")'
}

@test "preflight: text mode renders verdict + checks" {
  _baseline_deployable
  export CMD_JSON=""
  run cmd_preflight
  [[ "$output" == *"Preflight: demo (prod)"* ]]
  [[ "$output" == *"Verdict:"* ]]
}

@test "preflight: --help prints usage and exits 0" {
  run cmd_preflight --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: strut <stack> preflight"* ]]
}
