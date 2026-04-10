#!/usr/bin/env bash
# ==================================================
# lib/drift/metrics.sh — Drift detection Prometheus metrics
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Exports drift detection metrics for Prometheus

# Source utils if not already sourced
set -euo pipefail

if [ -z "$RED" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$SCRIPT_DIR/utils.sh"
fi

# drift_metrics_export <stack> <env>
# Exports drift detection metrics in Prometheus format
drift_metrics_export() {
  local stack="$1"
  local env="${2:-prod}"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local stack_dir="$cli_root/stacks/$stack"
  local metrics_dir="$stack_dir/metrics"
  mkdir -p "$metrics_dir"

  local metrics_file="$metrics_dir/drift.prom"

  # Detect current drift status
  local drifted_files_count=0
  local drift_detected=0

  # Source drift detection functions
  source "$cli_root/lib/drift.sh"

  drift_load_ignore_patterns "$stack_dir"

  for tracked_file in "${DRIFT_TRACKED_FILES[@]}"; do
    local git_file="$stack_dir/$tracked_file"
    local vps_file="$stack_dir/$tracked_file"

    [ -f "$git_file" ] || continue
    drift_should_ignore "$git_file" "$stack_dir" && continue

    local git_hash
    local vps_hash
    git_hash=$(drift_get_git_hash "$git_file")
    vps_hash=$(drift_get_vps_hash "$vps_file")

    if [ "$git_hash" != "$vps_hash" ]; then
      drifted_files_count=$((drifted_files_count + 1))
      drift_detected=1
    fi
  done

  # Write metrics in Prometheus format
  cat >"$metrics_file" <<EOF
# HELP ch_deploy_drift_detected Configuration drift detection status (1=drift detected, 0=no drift)
# TYPE ch_deploy_drift_detected gauge
ch_deploy_drift_detected{stack="$stack",env="$env"} $drift_detected

# HELP ch_deploy_drift_files_count Number of files with configuration drift
# TYPE ch_deploy_drift_files_count gauge
ch_deploy_drift_files_count{stack="$stack",env="$env"} $drifted_files_count

# HELP ch_deploy_drift_last_check_timestamp Unix timestamp of last drift check
# TYPE ch_deploy_drift_last_check_timestamp gauge
ch_deploy_drift_last_check_timestamp{stack="$stack",env="$env"} $(date +%s)
EOF

  return 0
}
