#!/usr/bin/env bash
# ==================================================
# lib/cmd_briefing.sh — one-call operational situation report
# ==================================================
# `strut <stack> briefing [--env <name>] [--json]`
#
# Fans out every read-only check for a stack (health, config drift, image
# staleness, pending diff, backup health), normalizes each into a common
# severity, computes an overall posture (worst-wins), and lists what needs
# attention with the exact remediation command for each finding. Aggregation
# only — no new detection logic (see lib/briefing.sh).

set -euo pipefail

_usage_briefing() {
  cat <<'EOF'

Usage: strut <stack> briefing [--env <name>] [--json]

One-call situation report. Aggregates health, config drift, image staleness,
pending diff, and backup health into a single posture (ok / warn / critical),
plus a prioritized list of recommended actions.

Flags:
  --env <name>     Environment to inspect (default: prod)
  --json           Structured JSON for CI, dashboards, and MCP

Exit code: 0 when posture is ok; non-zero when warn/critical/unknown, so CI
and scripts can gate on it.
EOF
}

# cmd_briefing [args] — reads CMD_STACK / CMD_ENV_NAME / CMD_JSON
cmd_briefing() {
  local a
  for a in "$@"; do
    case "$a" in --help|-h) _usage_briefing; return 0 ;; esac
  done

  local stack="${CMD_STACK:-}"
  local env="${CMD_ENV_NAME:-}"
  [ -z "$env" ] && env="prod"
  local json_mode="false"
  { [ "${CMD_JSON:-}" = "--json" ] || [ "${OUTPUT_MODE:-}" = "json" ]; } && json_mode="true"

  local -a dims=(health drift images diff backups)
  local -a sevs=() summaries=()

  local dim out rc result sev summary
  for dim in "${dims[@]}"; do
    out=""; rc=0
    case "$dim" in
      health)  out=$(_briefing_run "$stack" health --env "$env" --json)       || rc=$?; result=$(_briefing_norm_health "$out" "$rc") ;;
      drift)   out=$(_briefing_run "$stack" drift detect --env "$env")         || rc=$?; result=$(_briefing_norm_drift  "$out" "$rc") ;;
      images)  out=$(_briefing_run "$stack" drift images --json --env "$env")  || rc=$?; result=$(_briefing_norm_images "$out" "$rc") ;;
      diff)    out=$(_briefing_run "$stack" diff --json --env "$env")          || rc=$?; result=$(_briefing_norm_diff   "$out" "$rc") ;;
      backups) out=$(_briefing_run "$stack" backup health --env "$env" --json) || rc=$?; result=$(_briefing_norm_backup "$out" "$rc") ;;
    esac
    IFS=$'\t' read -r sev summary <<<"$result"
    sevs+=("$sev")
    summaries+=("$summary")
  done

  local posture
  posture=$(_briefing_posture "${sevs[@]}")

  # Prioritized actions: only dimensions WORSE than ok (warn/critical), worst
  # first. `unknown` ranks below ok — it means "couldn't assess", not a defect
  # to remediate — so it is surfaced in the dimensions table but never gets a
  # (misleading) fix command in the actions list.
  local -a sorted_idx=()
  local i
  local non_ok=""
  for i in "${!dims[@]}"; do
    case "${sevs[$i]}" in warn|critical) ;; *) continue ;; esac
    non_ok+="$(_briefing_sev_rank "${sevs[$i]}"):$i"$'\n'
  done
  if [ -n "$non_ok" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && sorted_idx+=("${line#*:}")
    done < <(printf '%s' "$non_ok" | sort -rn -t: -k1,1)
  fi

  if [ "$json_mode" = "true" ]; then
    OUTPUT_MODE=json
    out_json_object
      out_json_field "stack" "$stack"
      out_json_field "env" "$env"
      out_json_field "generated_at" "$(date -u +%FT%TZ)"
      out_json_field "posture" "$posture"
      out_json_array "dimensions"
        for i in "${!dims[@]}"; do
          out_json_object
            out_json_field "name" "${dims[$i]}"
            out_json_field "severity" "${sevs[$i]}"
            out_json_field "summary" "${summaries[$i]}"
          out_json_close_object
        done
      out_json_close_array
      out_json_array "actions"
        for i in "${sorted_idx[@]+"${sorted_idx[@]}"}"; do
          out_json_object
            out_json_field "severity" "${sevs[$i]}"
            out_json_field "dimension" "${dims[$i]}"
            out_json_field "summary" "${summaries[$i]}"
            out_json_field "command" "$(_briefing_remedy "${dims[$i]}" "$stack" "$env")"
          out_json_close_object
        done
      out_json_close_array
    out_json_close_object
    out_json_newline
  else
    echo ""
    echo -e "${BLUE}Briefing: ${stack} (${env})${NC}"
    echo -e "Posture: $(_briefing_glyph "$posture")"
    echo ""
    out_table_header "Dimension" "Status" "Detail"
    for i in "${!dims[@]}"; do
      out_table_row "${dims[$i]}" "$(_briefing_glyph "${sevs[$i]}")" "${summaries[$i]}"
    done
    out_table_render
    if [ "${#sorted_idx[@]}" -gt 0 ]; then
      echo ""
      echo "Recommended actions:"
      for i in "${sorted_idx[@]}"; do
        echo -e "  • [$(_briefing_glyph "${sevs[$i]}")] ${summaries[$i]}"
        echo    "      → $(_briefing_remedy "${dims[$i]}" "$stack" "$env")"
      done
    fi
    echo ""
  fi

  [ "$posture" = "ok" ] && return 0
  return 1
}
