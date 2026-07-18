#!/usr/bin/env bash
# ==================================================
# lib/cmd_preflight.sh — deploy go/no-go safety check
# ==================================================
# `strut <stack> preflight [--env <name>] [--json]`
#
# Fuses the deploy-relevant read-only checks (pending diff, config drift,
# current health, backup freshness) into a single verdict — GO / CAUTION /
# NO-GO — with the reasons behind it and the pre-steps to take first. Reuses
# lib/briefing.sh normalizers; adds only the release-safety decision logic.
#
# Exit codes:  GO → 0,  CAUTION → 1,  NO-GO → 2  (automation can branch on all
# three).

set -euo pipefail

_usage_preflight() {
  cat <<'EOF'

Usage: strut <stack> preflight [--env <name>] [--json]

Deploy go/no-go. Evaluates pending diff, config drift, current health, and
backup freshness, then returns one verdict:

  GO       Safe to deploy.
  CAUTION  Deployable, but review the listed risks first (unhealthy base,
           destructive changes, or stale backups).
  NO-GO    Do not deploy — config drift would be overwritten, or deploy
           safety could not be assessed.

Flags:
  --env <name>     Environment to check (default: prod)
  --json           Structured JSON for CI, dashboards, and MCP

Exit code: GO → 0, CAUTION → 1, NO-GO → 2.
EOF
}

# _preflight_verdict_glyph <verdict>
_preflight_verdict_glyph() {
  case "$1" in
    GO)      printf '%b' "${GREEN}✓ GO${NC}" ;;
    CAUTION) printf '%b' "${YELLOW}⚠ CAUTION${NC}" ;;
    NO-GO)   printf '%b' "${RED}✗ NO-GO${NC}" ;;
    *)       printf '%s' "$1" ;;
  esac
}

# _preflight_reason_glyph <severity>
_preflight_reason_glyph() {
  case "$1" in
    critical) printf '%b' "${RED}✗${NC}" ;;
    warn)     printf '%b' "${YELLOW}⚠${NC}" ;;
    info)     printf '%b' "${BLUE}ℹ${NC}" ;;
    *)        printf '%s' "•" ;;
  esac
}

# cmd_preflight [args] — reads CMD_STACK / CMD_ENV_NAME / CMD_JSON
cmd_preflight() {
  local a
  for a in "$@"; do
    case "$a" in --help|-h) _usage_preflight; return 0 ;; esac
  done

  local stack="${CMD_STACK:-}"
  local env="${CMD_ENV_NAME:-}"
  [ -z "$env" ] && env="prod"
  local json_mode="false"
  { [ "${CMD_JSON:-}" = "--json" ] || [ "${OUTPUT_MODE:-}" = "json" ]; } && json_mode="true"

  # ── Gather the deploy-relevant dimensions (reused normalizers) ──────────────
  local out rc result
  local s_diff s_drift s_health s_backups

  out=""; rc=0
  out=$(_briefing_run "$stack" diff --json --env "$env") || rc=$?
  result=$(_briefing_norm_diff "$out" "$rc"); s_diff="${result%%$'\t'*}"

  out=""; rc=0
  out=$(_briefing_run "$stack" drift detect --env "$env") || rc=$?
  result=$(_briefing_norm_drift "$out" "$rc"); s_drift="${result%%$'\t'*}"

  out=""; rc=0
  out=$(_briefing_run "$stack" health --env "$env" --json) || rc=$?
  result=$(_briefing_norm_health "$out" "$rc"); s_health="${result%%$'\t'*}"

  out=""; rc=0
  out=$(_briefing_run "$stack" backup health --env "$env" --json) || rc=$?
  result=$(_briefing_norm_backup "$out" "$rc"); s_backups="${result%%$'\t'*}"

  # ── Verdict logic ───────────────────────────────────────────────────────────
  local -a r_sev=() r_msg=() r_cmd=()
  local nogo="false" caution="false"

  # NO-GO gates
  if [ "$s_drift" = "critical" ]; then
    r_sev+=("critical")
    r_msg+=("Config drift detected on the VPS — deploying would overwrite un-committed changes")
    r_cmd+=("strut $stack drift fix --env $env")
    nogo="true"
  fi
  if [ "$s_diff" = "unknown" ] && [ "$s_drift" = "unknown" ]; then
    r_sev+=("critical")
    r_msg+=("Cannot assess deploy safety — no remote target configured or checks unavailable")
    r_cmd+=("strut $stack diff --env $env")
    nogo="true"
  fi

  # CAUTION gates
  if [ "$s_health" = "critical" ]; then
    r_sev+=("warn")
    r_msg+=("Stack is currently unhealthy — deploying onto a broken base")
    r_cmd+=("strut $stack logs --env $env")
    caution="true"
  elif [ "$s_health" = "warn" ]; then
    # Degraded is milder than unhealthy — surfaced for transparency, but it
    # does not block a deploy on its own (a deploy often restores it).
    r_sev+=("info")
    r_msg+=("Stack is degraded — some containers are not fully healthy")
    r_cmd+=("strut $stack health --env $env")
  fi
  if [ "$s_diff" = "critical" ]; then
    r_sev+=("warn")
    r_msg+=("Pending changes include destructive operations (data-loss risk)")
    r_cmd+=("strut $stack diff --env $env")
    caution="true"
  fi
  if [ "$s_backups" = "warn" ] || [ "$s_backups" = "critical" ]; then
    r_sev+=("warn")
    r_msg+=("No recent healthy backup — back up before deploying")
    r_cmd+=("strut $stack backup all --env $env")
    caution="true"
  fi

  # Informational (never changes a GO on its own)
  if [ "$s_diff" = "ok" ]; then
    r_sev+=("info")
    r_msg+=("No pending changes to deploy")
    r_cmd+=("strut $stack diff --env $env")
  elif [ "$s_diff" = "warn" ]; then
    r_sev+=("info")
    r_msg+=("Pending changes are ready to deploy")
    r_cmd+=("strut $stack deploy --env $env")
  fi

  local verdict="GO"
  if [ "$nogo" = "true" ]; then
    verdict="NO-GO"
  elif [ "$caution" = "true" ]; then
    verdict="CAUTION"
  fi

  # ── Output ──────────────────────────────────────────────────────────────────
  if [ "$json_mode" = "true" ]; then
    OUTPUT_MODE=json
    out_json_object
      out_json_field "stack" "$stack"
      out_json_field "env" "$env"
      out_json_field "generated_at" "$(date -u +%FT%TZ)"
      out_json_field "verdict" "$verdict"
      # checks is a flat object of fixed-vocabulary severities (ok/warn/
      # critical/unknown) — safe to assemble as a raw value, no escaping needed.
      out_json_field_raw "checks" \
        "{\"diff\":\"$s_diff\",\"drift\":\"$s_drift\",\"health\":\"$s_health\",\"backups\":\"$s_backups\"}"
      out_json_array "reasons"
        if [ "${#r_sev[@]}" -gt 0 ]; then
          local i
          for i in "${!r_sev[@]}"; do
            out_json_object
              out_json_field "severity" "${r_sev[$i]}"
              out_json_field "message" "${r_msg[$i]}"
              out_json_field "command" "${r_cmd[$i]}"
            out_json_close_object
          done
        fi
      out_json_close_array
    out_json_close_object
    out_json_newline
  else
    echo ""
    echo -e "${BLUE}Preflight: ${stack} (${env})${NC}"
    echo -e "Verdict: $(_preflight_verdict_glyph "$verdict")"
    echo ""
    out_table_header "Check" "Status"
    out_table_row "diff"    "$(_briefing_glyph "$s_diff")"
    out_table_row "drift"   "$(_briefing_glyph "$s_drift")"
    out_table_row "health"  "$(_briefing_glyph "$s_health")"
    out_table_row "backups" "$(_briefing_glyph "$s_backups")"
    out_table_render
    if [ "${#r_sev[@]}" -gt 0 ]; then
      echo ""
      echo "Reasons:"
      local i
      for i in "${!r_sev[@]}"; do
        echo -e "  $(_preflight_reason_glyph "${r_sev[$i]}") ${r_msg[$i]}"
        echo    "      → ${r_cmd[$i]}"
      done
    fi
    echo ""
  fi

  case "$verdict" in
    GO)      return 0 ;;
    CAUTION) return 1 ;;
    NO-GO)   return 2 ;;
  esac
}
