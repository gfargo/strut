#!/usr/bin/env bash
# ==================================================
# lib/backup/health.sh — Backup health scoring
# ==================================================
# Requires: lib/utils.sh sourced first
#
# Calculates backup health scores based on success rate and verification

# calculate_backup_success_rate <stack> <service> <days>
# Calculates backup success rate over the specified period
set -euo pipefail

calculate_backup_success_rate() {
  local stack="$1"
  local service="$2"
  local days="${3:-7}"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_dir="$cli_root/stacks/$stack/backups"
  local metadata_dir="$backup_dir/metadata"

  [ -d "$metadata_dir" ] || {
    warn "No metadata directory found"
    echo "0"
    return 1
  }

  local now
  now=$(date +%s)
  local cutoff=$((now - (days * 86400)))

  local total=0
  local successful=0

  # Count backups in the time period
  for metadata_file in "$metadata_dir/${service}-"*.json; do
    [ -f "$metadata_file" ] || continue

    # Get backup timestamp
    local backup_time
    backup_time=$(stat -c%Y "$metadata_file" 2>/dev/null || stat -f%m "$metadata_file" 2>/dev/null)

    # Skip if outside time window
    [ "$backup_time" -lt "$cutoff" ] && continue

    total=$((total + 1))

    # Check if backup was successful (file exists and has verification status)
    if command -v jq &>/dev/null; then
      local verification_status
      verification_status=$(jq -r '.verification.status' "$metadata_file" 2>/dev/null)

      if [ "$verification_status" = "passed" ] || [ "$verification_status" = "pending" ]; then
        successful=$((successful + 1))
      fi
    else
      # Fallback: assume successful if metadata exists
      successful=$((successful + 1))
    fi
  done

  # Calculate success rate
  if [ $total -eq 0 ]; then
    echo "0"
    return 0
  fi

  local success_rate=$((successful * 100 / total))
  echo "$success_rate"
}

# calculate_verification_rate <stack> <service> <days>
# Calculates verification success rate over the specified period
calculate_verification_rate() {
  local stack="$1"
  local service="$2"
  local days="${3:-7}"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local metadata_dir="$cli_root/stacks/$stack/backups/metadata"

  [ -d "$metadata_dir" ] || {
    warn "No metadata directory found"
    echo "0"
    return 1
  }

  local now
  now=$(date +%s)
  local cutoff=$((now - (days * 86400)))

  local total=0
  local verified=0

  # Count verified backups in the time period
  for metadata_file in "$metadata_dir/${service}-"*.json; do
    [ -f "$metadata_file" ] || continue

    # Get backup timestamp
    local backup_time
    backup_time=$(stat -c%Y "$metadata_file" 2>/dev/null || stat -f%m "$metadata_file" 2>/dev/null)

    # Skip if outside time window
    [ "$backup_time" -lt "$cutoff" ] && continue

    total=$((total + 1))

    # Check verification status
    if command -v jq &>/dev/null; then
      local verification_status
      verification_status=$(jq -r '.verification.status' "$metadata_file" 2>/dev/null)

      if [ "$verification_status" = "passed" ]; then
        verified=$((verified + 1))
      fi
    fi
  done

  # Calculate verification rate
  if [ $total -eq 0 ]; then
    echo "0"
    return 0
  fi

  local verification_rate=$((verified * 100 / total))
  echo "$verification_rate"
}

# calculate_backup_health_score <stack> <service>
# Calculates overall backup health score (0-100)
calculate_backup_health_score() {
  local stack="$1"
  local service="$2"

  # Get success rates for different periods
  local success_7d
  success_7d=$(calculate_backup_success_rate "$stack" "$service" 7)

  local success_30d
  success_30d=$(calculate_backup_success_rate "$stack" "$service" 30)

  local verification_7d
  verification_7d=$(calculate_verification_rate "$stack" "$service" 7)

  # Calculate weighted health score
  # 40% weight on 7-day success rate
  # 30% weight on 30-day success rate
  # 30% weight on verification rate
  local health_score=$(((success_7d * 40 + success_30d * 30 + verification_7d * 30) / 100))

  echo "$health_score"
}

# get_backup_health_status <stack> <service>
# Returns health status and detailed metrics
get_backup_health_status() {
  local stack="$1"
  local service="$2"

  local health_score
  health_score=$(calculate_backup_health_score "$stack" "$service")

  local success_7d
  success_7d=$(calculate_backup_success_rate "$stack" "$service" 7)

  local success_30d
  success_30d=$(calculate_backup_success_rate "$stack" "$service" 30)

  local verification_7d
  verification_7d=$(calculate_verification_rate "$stack" "$service" 7)

  # Determine health status
  local status="UNKNOWN"
  local status_color=""

  if [ "$health_score" -ge 90 ]; then
    status="HEALTHY"
    status_color="\033[0;32m" # Green
  elif [ "$health_score" -ge 70 ]; then
    status="WARNING"
    status_color="\033[0;33m" # Yellow
  elif [ "$health_score" -ge 50 ]; then
    status="DEGRADED"
    status_color="\033[0;31m" # Red
  else
    status="CRITICAL"
    status_color="\033[1;31m" # Bold Red
  fi

  # Display health status
  echo -e "${status_color}Backup Health: $status (Score: $health_score/100)\033[0m"
  echo ""
  echo "Metrics:"
  echo "  7-day success rate:    ${success_7d}%"
  echo "  30-day success rate:   ${success_30d}%"
  echo "  7-day verification:    ${verification_7d}%"
  echo ""

  # Return health score for scripting
  return "$health_score"
}

# get_backup_health_json <stack> <service>
# Returns health status as JSON
get_backup_health_json() {
  local stack="$1"
  local service="$2"

  local health_score
  health_score=$(calculate_backup_health_score "$stack" "$service")

  local success_7d
  success_7d=$(calculate_backup_success_rate "$stack" "$service" 7)

  local success_30d
  success_30d=$(calculate_backup_success_rate "$stack" "$service" 30)

  local verification_7d
  verification_7d=$(calculate_verification_rate "$stack" "$service" 7)

  # Determine status
  local status="unknown"
  if [ "$health_score" -ge 90 ]; then
    status="healthy"
  elif [ "$health_score" -ge 70 ]; then
    status="warning"
  elif [ "$health_score" -ge 50 ]; then
    status="degraded"
  else
    status="critical"
  fi

  # Output JSON
  cat <<EOF
{
  "stack": "$stack",
  "service": "$service",
  "health_score": $health_score,
  "status": "$status",
  "metrics": {
    "success_rate_7d": $success_7d,
    "success_rate_30d": $success_30d,
    "verification_rate_7d": $verification_7d
  },
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# get_all_backup_health <stack>
# Returns health status for all services in a stack
get_all_backup_health() {
  local stack="$1"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local backup_dir="$cli_root/stacks/$stack/backups"

  [ -d "$backup_dir" ] || {
    error "Backup directory not found: $backup_dir"
    return 1
  }

  log "Backup health status for stack: $stack"
  echo ""

  # Check postgres
  if ls "$backup_dir"/postgres-*.sql >/dev/null 2>&1; then
    echo "=== PostgreSQL ==="
    get_backup_health_status "$stack" "postgres"
  fi

  # Check neo4j
  if ls "$backup_dir"/neo4j-*.dump >/dev/null 2>&1; then
    echo "=== Neo4j ==="
    get_backup_health_status "$stack" "neo4j"
  fi

  # Check mysql
  if ls "$backup_dir"/mysql-*.sql >/dev/null 2>&1; then
    echo "=== MySQL ==="
    get_backup_health_status "$stack" "mysql"
  fi

  # Check sqlite
  if ls "$backup_dir"/sqlite-*.db >/dev/null 2>&1; then
    echo "=== SQLite ==="
    get_backup_health_status "$stack" "sqlite"
  fi
}

# check_backup_health_alerts <stack> <service>
# Checks health score and sends alerts if below threshold
check_backup_health_alerts() {
  local stack="$1"
  local service="$2"

  local health_score
  health_score=$(calculate_backup_health_score "$stack" "$service")

  # Alert thresholds
  local critical_threshold=50
  local warning_threshold=70

  if [ "$health_score" -lt "$critical_threshold" ]; then
    # Critical alert
    local message="Backup health is CRITICAL for $service

Health Score: $health_score/100
Threshold: $critical_threshold

Action Required: Investigate backup failures immediately.
Command: strut $stack backup health --env prod"

    source "$cli_root/lib/backup/alerts.sh" 2>/dev/null
    send_backup_alert "$stack" "$service" "HEALTH_CRITICAL" "$message"

  elif [ "$health_score" -lt "$warning_threshold" ]; then
    # Warning alert
    local message="Backup health is DEGRADED for $service

Health Score: $health_score/100
Threshold: $warning_threshold

Action Required: Review backup logs and verification results.
Command: strut $stack backup health --env prod"

    source "$cli_root/lib/backup/alerts.sh" 2>/dev/null
    send_backup_alert "$stack" "$service" "HEALTH_WARNING" "$message"
  fi
}

# export_health_metrics <stack>
# Exports health metrics for Prometheus/Grafana
export_health_metrics() {
  local stack="$1"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local metrics_file="$cli_root/stacks/$stack/backups/health-metrics.prom"

  # Create Prometheus metrics file
  cat >"$metrics_file" <<EOF
# HELP backup_health_score Backup health score (0-100)
# TYPE backup_health_score gauge
EOF

  # Export postgres metrics
  if ls "$cli_root/stacks/$stack/backups"/postgres-*.sql >/dev/null 2>&1; then
    local postgres_score
    postgres_score=$(calculate_backup_health_score "$stack" "postgres")
    echo "backup_health_score{stack=\"$stack\",service=\"postgres\"} $postgres_score" >>"$metrics_file"
  fi

  # Export neo4j metrics
  if ls "$cli_root/stacks/$stack/backups"/neo4j-*.dump >/dev/null 2>&1; then
    local neo4j_score
    neo4j_score=$(calculate_backup_health_score "$stack" "neo4j")
    echo "backup_health_score{stack=\"$stack\",service=\"neo4j\"} $neo4j_score" >>"$metrics_file"
  fi

  # Export mysql metrics
  if ls "$cli_root/stacks/$stack/backups"/mysql-*.sql >/dev/null 2>&1; then
    local mysql_score
    mysql_score=$(calculate_backup_health_score "$stack" "mysql")
    echo "backup_health_score{stack=\"$stack\",service=\"mysql\"} $mysql_score" >>"$metrics_file"
  fi

  # Export sqlite metrics
  if ls "$cli_root/stacks/$stack/backups"/sqlite-*.db >/dev/null 2>&1; then
    local sqlite_score
    sqlite_score=$(calculate_backup_health_score "$stack" "sqlite")
    echo "backup_health_score{stack=\"$stack\",service=\"sqlite\"} $sqlite_score" >>"$metrics_file"
  fi

  ok "Health metrics exported to: $metrics_file"
}

# generate_health_dashboard_data <stack>
# Generates data for Grafana dashboard
generate_health_dashboard_data() {
  local stack="$1"

  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local dashboard_data="$cli_root/stacks/$stack/backups/health-dashboard.json"

  # Start JSON array
  echo "[" >"$dashboard_data"

  local first=true

  # Add postgres data
  if ls "$cli_root/stacks/$stack/backups"/postgres-*.sql >/dev/null 2>&1; then
    [ "$first" = false ] && echo "," >>"$dashboard_data"
    get_backup_health_json "$stack" "postgres" >>"$dashboard_data"
    first=false
  fi

  # Add neo4j data
  if ls "$cli_root/stacks/$stack/backups"/neo4j-*.dump >/dev/null 2>&1; then
    [ "$first" = false ] && echo "," >>"$dashboard_data"
    get_backup_health_json "$stack" "neo4j" >>"$dashboard_data"
    first=false
  fi

  # Add mysql data
  if ls "$cli_root/stacks/$stack/backups"/mysql-*.sql >/dev/null 2>&1; then
    [ "$first" = false ] && echo "," >>"$dashboard_data"
    get_backup_health_json "$stack" "mysql" >>"$dashboard_data"
    first=false
  fi

  # Add sqlite data
  if ls "$cli_root/stacks/$stack/backups"/sqlite-*.db >/dev/null 2>&1; then
    [ "$first" = false ] && echo "," >>"$dashboard_data"
    get_backup_health_json "$stack" "sqlite" >>"$dashboard_data"
    first=false
  fi

  # Close JSON array
  echo "]" >>"$dashboard_data"

  ok "Dashboard data generated: $dashboard_data"
}
