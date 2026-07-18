#!/usr/bin/env bash
# ==================================================
# lib/briefing.sh — shared aggregation primitives for briefing + preflight
# ==================================================
# Neither `briefing` nor `preflight` adds new detection logic. Both re-invoke
# strut's existing read-only checks (health, drift, drift images, diff, backup
# health), normalize each into a common four-level severity, and synthesize —
# a worst-wins posture (briefing) or a release-safety verdict (preflight).
#
# Design notes:
#   - Each check runs in its OWN strut process (see _briefing_run) so a
#     hard-failing check, a missing env file, or a timeout degrades that one
#     dimension to `unknown` instead of aborting the whole aggregation.
#   - Normalizers lean on each command's documented exit code, with guarded jq
#     parsing of the --json body as a richer secondary signal. Every jq call is
#     guarded so malformed JSON degrades to `unknown`, never a crash.

set -euo pipefail

# ── Severity model ────────────────────────────────────────────────────────────
# Four levels, ranked for max-comparison:  critical(3) > warn(2) > ok(1) > unknown(0)

# _briefing_sev_rank <severity> — numeric rank for worst-wins comparison
_briefing_sev_rank() {
  case "$1" in
    critical) echo 3 ;;
    warn)     echo 2 ;;
    ok)       echo 1 ;;
    *)        echo 0 ;;  # unknown
  esac
}

# _briefing_worst <sevA> <sevB> — the higher-ranked of two severities
_briefing_worst() {
  local a="$1" b="$2"
  if [ "$(_briefing_sev_rank "$a")" -ge "$(_briefing_sev_rank "$b")" ]; then
    echo "$a"
  else
    echo "$b"
  fi
}

# _briefing_posture <sev...> — overall posture across dimensions.
#
# Worst-wins among ok/warn/critical. `unknown` never dominates a real signal;
# the posture only becomes `unknown` when NO dimension reached ok-or-worse
# (i.e. every dimension was unknown).
_briefing_posture() {
  local worst="unknown" sev
  for sev in "$@"; do
    worst=$(_briefing_worst "$worst" "$sev")
  done
  echo "$worst"
}

# ── Isolated check runner ─────────────────────────────────────────────────────

# _briefing_bin — absolute path to the strut entrypoint to re-invoke.
# Matches how lib/mcp/tools.sh resolves the binary.
_briefing_bin() {
  local home="${STRUT_HOME:-${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
  printf '%s' "$home/strut"
}

# _briefing_run <strut-args...> — run one check in an isolated strut process.
#
# Captures stdout only (stderr is dropped so log/warn noise can't corrupt a
# JSON body). NEVER aborts the caller: it is always invoked as
# `out=$(_briefing_run ...) || rc=$?`, so the child's exit code is handed to
# the normalizer rather than tripping `set -e`. When `timeout`/`gtimeout` is
# available the check is capped (default 45s) — using the OS timeout rather
# than a hand-rolled background PID avoids orphaned SSH children on the fast
# path. A timed-out check exits 124, which normalizers treat as `unknown`.
_briefing_run() {
  local bin
  bin=$(_briefing_bin)
  local secs="${STRUT_BRIEFING_TIMEOUT:-45}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$bin" "$@" 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$bin" "$@" 2>/dev/null
  else
    "$bin" "$@" 2>/dev/null
  fi
}

# _briefing_json_extract — stdin -> stdout, from the first `{`/`[` line onward.
# Drops any leading log/ok lines a check prints before its JSON body.
_briefing_json_extract() {
  awk 'f{print; next} /^[[:space:]]*[{[]/{f=1; print}'
}

# ── Per-dimension normalizers ─────────────────────────────────────────────────
# Each echoes:  <severity><TAB><one-line summary>
# Callers read with:  IFS=$'\t' read -r sev summary <<<"$result"

# _briefing_norm_health <stdout> <rc>
# health --json emits {"overall_status":"healthy|degraded|unhealthy","checks":[…]}
# and returns 0/1/2. Prefer the parsed overall_status; fall back to rc.
_briefing_norm_health() {
  local out="$1" rc="$2"
  [ "$rc" = "124" ] && { printf 'unknown\thealth check timed out'; return 0; }

  local json overall total running summary=""
  json=$(printf '%s' "$out" | _briefing_json_extract)
  overall=$(printf '%s' "$json" | jq -r '.overall_status // empty' 2>/dev/null) || overall=""
  total=$(printf '%s' "$json"   | jq -r '[.checks[]? | select(.name|startswith("Container:"))] | length' 2>/dev/null) || total=""
  running=$(printf '%s' "$json" | jq -r '[.checks[]? | select(.name|startswith("Container:")) | select(.status=="pass" or .status=="warn")] | length' 2>/dev/null) || running=""

  if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
    summary="${running:-0}/${total} containers healthy"
  fi

  case "$overall" in
    healthy)   printf 'ok\t%s'       "${summary:-all checks passing}" ;;
    degraded)  printf 'warn\t%s'     "${summary:-system degraded}" ;;
    unhealthy) printf 'critical\t%s' "${summary:-system unhealthy}" ;;
    *)
      case "$rc" in
        0) printf 'ok\t%s'       "${summary:-healthy}" ;;
        1) printf 'warn\t%s'     "${summary:-degraded}" ;;
        2) printf 'critical\t%s' "${summary:-unhealthy}" ;;
        *) printf 'unknown\thealth check unavailable' ;;
      esac
      ;;
  esac
}

# _briefing_norm_drift <stdout> <rc>
# `drift detect` returns 0 in-sync, non-zero when drift is found. A hard error
# (no remote target, missing files) also exits non-zero but prints nothing to
# stdout (its message goes to stderr, which _briefing_run drops) — so a
# non-zero rc with EMPTY stdout is treated as `unknown` rather than drift.
_briefing_norm_drift() {
  local out="$1" rc="$2"
  [ "$rc" = "124" ] && { printf 'unknown\tdrift check timed out'; return 0; }
  if [ "$rc" = "0" ]; then
    printf 'ok\tconfig in sync'
  elif [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    printf 'critical\tconfiguration drift detected'
  else
    printf 'unknown\tdrift check unavailable'
  fi
}

# _briefing_norm_images <stdout> <rc>
# `drift images --json` emits {"total":N,"drifted":M,...}. No JSON (e.g. no
# running containers) -> unknown.
_briefing_norm_images() {
  local out="$1" rc="$2"
  [ "$rc" = "124" ] && { printf 'unknown\timage check timed out'; return 0; }
  local json drifted total
  json=$(printf '%s' "$out" | _briefing_json_extract)
  drifted=$(printf '%s' "$json" | jq -r '.drifted // empty' 2>/dev/null) || drifted=""
  total=$(printf '%s' "$json"   | jq -r '.total // empty'   2>/dev/null) || total=""
  if [ -z "$drifted" ]; then
    printf 'unknown\timage check unavailable'
  elif [ "$drifted" -gt 0 ] 2>/dev/null; then
    printf 'warn\t%s/%s images have stale digests' "$drifted" "${total:-?}"
  else
    printf 'ok\tall %s images current' "${total:-0}"
  fi
}

# _briefing_norm_diff <stdout> <rc>
# `diff --json` emits {"has_changes":bool,"has_destructive_changes":bool,…} and
# returns 0 (none) / 1 (changes) / 2 (hard error: no VPS_HOST, missing files).
# No parseable JSON -> unknown.
_briefing_norm_diff() {
  local out="$1" rc="$2"
  [ "$rc" = "124" ] && { printf 'unknown\tdiff check timed out'; return 0; }
  local json has hasd
  json=$(printf '%s' "$out" | _briefing_json_extract)
  # NB: `.has_changes // empty` is WRONG here — jq's // treats a literal
  # `false` as empty, so a clean "no changes" diff would look unavailable.
  # Check key presence explicitly and stringify the boolean instead.
  has=$(printf '%s' "$json" | jq -r 'if type=="object" and has("has_changes") then (.has_changes|tostring) else "MISSING" end' 2>/dev/null) || has="MISSING"
  hasd=$(printf '%s' "$json" | jq -r 'if type=="object" and (.has_destructive_changes==true) then "true" else "false" end' 2>/dev/null) || hasd="false"
  # Anything other than an explicit true/false (empty stdin, parse failure,
  # missing key) means we could not read the diff — degrade to unknown.
  case "$has" in
    true)
      if [ "$hasd" = "true" ]; then
        printf 'critical\tdestructive pending changes'
      else
        printf 'warn\tpending changes to deploy'
      fi
      ;;
    false) printf 'ok\tno pending changes' ;;
    *)     printf 'unknown\tdiff unavailable (no remote target?)' ;;
  esac
}

# _briefing_norm_backup <stdout> <rc>
# `backup health all --json` emits an ARRAY of per-engine {"status":…,
# "health_score":…}. Severity is the worst engine status. Empty array / no
# backups recorded -> unknown.
_briefing_norm_backup() {
  local out="$1" rc="$2"
  [ "$rc" = "124" ] && { printf 'unknown\tbackup check timed out'; return 0; }
  local json count worst
  json=$(printf '%s' "$out" | _briefing_json_extract)
  count=$(printf '%s' "$json" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null) || count=""
  if [ -z "$count" ] || [ "$count" = "0" ]; then
    printf 'unknown\tno backups recorded'
    return 0
  fi
  worst=$(printf '%s' "$json" | jq -r '
    [.[].status] |
    if   any(.=="critical") then "critical"
    elif any(.=="degraded") then "degraded"
    elif any(.=="warning")  then "warning"
    elif all(.=="healthy")  then "healthy"
    else "unknown" end' 2>/dev/null) || worst="unknown"
  case "$worst" in
    healthy)          printf 'ok\tbackups healthy' ;;
    warning)          printf 'warn\tbackup health warning' ;;
    degraded|critical) printf 'critical\tbackup health %s' "$worst" ;;
    *)                printf 'unknown\tbackup status unclear' ;;
  esac
}

# ── Remediation commands ──────────────────────────────────────────────────────

# _briefing_remedy <dimension> <stack> <env> — the exact command that addresses
# a non-ok dimension, so an operator (or agent) can act without guessing.
_briefing_remedy() {
  local dim="$1" stack="$2" env="$3"
  case "$dim" in
    health)  printf 'strut %s logs --env %s'          "$stack" "$env" ;;
    drift)   printf 'strut %s drift fix --env %s'      "$stack" "$env" ;;
    images)  printf 'strut %s deploy --env %s'         "$stack" "$env" ;;
    diff)    printf 'strut %s deploy --env %s'         "$stack" "$env" ;;
    backups) printf 'strut %s backup all --env %s'     "$stack" "$env" ;;
    *)       printf 'strut %s health --env %s'         "$stack" "$env" ;;
  esac
}

# _briefing_glyph <severity> — colored one-word status for human output.
_briefing_glyph() {
  case "$1" in
    ok)       printf '%b' "${GREEN}✓${NC} ok" ;;
    warn)     printf '%b' "${YELLOW}⚠${NC} warn" ;;
    critical) printf '%b' "${RED}✗${NC} critical" ;;
    *)        printf '%s' "? unknown" ;;
  esac
}
