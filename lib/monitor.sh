#!/usr/bin/env bash
# ==================================================
# lib/monitor.sh — Monitoring stack management
# ==================================================
# Provides commands for deploying and managing the
# self-hosted monitoring stack (Prometheus/Grafana/Alertmanager)

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# ── Constants ─────────────────────────────────────────────────────────────────
MONITORING_STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stacks/monitoring" && pwd)"

# ── Helper Functions ──────────────────────────────────────────────────────────

# monitoring_is_running
#
# Checks whether the core monitoring services (Prometheus, Grafana,
# Alertmanager) are all running.
#
# Returns: 0 if all three are running, 1 otherwise
monitoring_is_running() {
  docker ps | grep -q prometheus && \
  docker ps | grep -q grafana && \
  docker ps | grep -q alertmanager
}

# wait_for_service <service_name> <url> [max_wait]
#
# Polls a URL until it returns a successful response, or times out.
#
# Args:
#   service_name — Display name for log messages
#   url          — Health check URL to poll
#   max_wait     — Timeout in seconds (default: 60)
# Returns: 0 on success, 1 on timeout
wait_for_service() {
  local service_name="$1"
  local url="$2"
  local max_wait="${3:-60}"

  log "Waiting for $service_name to be ready..."
  for i in $(seq 1 "$max_wait"); do
    if curl -s "$url" > /dev/null 2>&1; then
      ok "$service_name is ready"
      return 0
    fi
    sleep 1
  done

  error "$service_name failed to start within ${max_wait}s"
  return 1
}

# ── Main Commands ─────────────────────────────────────────────────────────────

# monitoring_deploy [env]
#
# Deploys the self-hosted monitoring stack (Prometheus, Grafana, Alertmanager)
# using docker-compose in the monitoring stack directory.
#
# Args:
#   env — Environment name (default: "prod")
# Requires env: GRAFANA_ADMIN_PASSWORD, RESEND_API_KEY (via .env)
# Side effects: Pulls images, starts containers, waits for health
monitoring_deploy() {
  local env="${1:-prod}"

  log "Deploying monitoring stack..."

  # Check if monitoring directory exists
  if [ ! -d "$MONITORING_STACK_DIR" ]; then
    fail "Monitoring stack directory not found: $MONITORING_STACK_DIR"
  fi

  cd "$MONITORING_STACK_DIR" || fail "Failed to cd to monitoring directory"

  # Check if .env exists
  if [ ! -f ".env" ]; then
    warn ".env file not found. Creating from template..."
    if [ -f ".env.template" ]; then
      cp .env.template .env
      warn "Please edit .env and configure:"
      warn "  - GRAFANA_ADMIN_PASSWORD"
      warn "  - RESEND_API_KEY"
      warn "  - ALERT_EMAIL_TO"
      warn "  - ALERT_EMAIL_FROM"
      echo
      read -p "Press Enter after configuring .env to continue..."
    else
      fail ".env.template not found"
    fi
  fi

  # Validate docker-compose.yml
  log "Validating docker-compose.yml..."
  if ! docker-compose config > /dev/null 2>&1; then
    fail "Invalid docker-compose.yml"
  fi
  ok "Configuration valid"

  # Pull images
  log "Pulling Docker images..."
  docker-compose pull || fail "Failed to pull images"

  # Start services
  log "Starting monitoring services..."
  docker-compose up -d || fail "Failed to start services"

  # Load monitoring services config
  local monitoring_conf="$MONITORING_STACK_DIR/services.conf"
  # shellcheck disable=SC1090
  [ -f "$monitoring_conf" ] && source "$monitoring_conf"

  local prometheus_port="${PROMETHEUS_PORT:-9090}"
  local prometheus_health="${PROMETHEUS_HEALTH_PATH:-/-/ready}"
  local grafana_port="${GRAFANA_PORT:-3000}"
  local grafana_health="${GRAFANA_HEALTH_PATH:-/api/health}"
  local alertmanager_port="${ALERTMANAGER_PORT:-9093}"
  local alertmanager_health="${ALERTMANAGER_HEALTH_PATH:-/-/ready}"

  # Wait for services to be ready
  wait_for_service "Prometheus" "http://localhost:${prometheus_port}${prometheus_health}" 60
  wait_for_service "Grafana" "http://localhost:${grafana_port}${grafana_health}" 60
  wait_for_service "Alertmanager" "http://localhost:${alertmanager_port}${alertmanager_health}" 60

  echo
  ok "Monitoring stack deployed successfully!"
  echo
  echo "Access points:"
  echo "  Prometheus:   http://localhost:${prometheus_port}"
  echo "  Grafana:      http://localhost:${grafana_port} (admin / check .env for password)"
  echo "  Alertmanager: http://localhost:${alertmanager_port}"
  echo
  echo "Next steps:"
  echo "  1. Add stacks to monitoring: strut monitoring add-target <stack>"
  echo "  2. Configure alert channels: strut monitoring alert-channel add email"
  echo "  3. Test alerts: strut monitoring alert-channel test email"
}

# monitoring_add_target <stack_name> [env]
#
# Adds a stack to Prometheus monitoring by creating a target YAML file.
# Reloads Prometheus config if the monitoring stack is running.
#
# Args:
#   stack_name — Name of the stack to monitor
#   env        — Environment label (default: "prod")
# Side effects: Creates prometheus/targets/<stack>.yml, reloads Prometheus
monitoring_add_target() {
  local stack_name="$1"
  local env="${2:-prod}"

  if [ -z "$stack_name" ]; then
    fail "Usage: monitoring add-target <stack-name> [env]"
  fi

  log "Adding $stack_name to monitoring targets..."

  local target_file="$MONITORING_STACK_DIR/prometheus/targets/${stack_name}.yml"

  # Check if target file already exists
  if [ -f "$target_file" ]; then
    warn "Target file already exists: $target_file"
    read -p "Overwrite? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      log "Aborted"
      return 0
    fi
  fi

  # Determine VPS instance
  local vps_instance="vps-1"
  if [ "$stack_name" = "twenty" ] || [ "$stack_name" = "twenty-mcp" ]; then
    vps_instance="vps-2"
  fi

  # Create target file
  cat > "$target_file" <<EOF
# ${stack_name} stack monitoring targets
# This file is auto-generated by strut monitoring commands
# Manual edits will be preserved but may be overwritten

- targets:
    # Add application metrics endpoints here
    # Example: - 'service-name:port'
  labels:
    stack: '${stack_name}'
    vps: '${vps_instance}'
    environment: '${env}'
EOF

  ok "Target file created: $target_file"

  # Reload Prometheus if running
  if monitoring_is_running; then
    log "Reloading Prometheus configuration..."
    if docker exec prometheus kill -HUP 1 2>/dev/null; then
      ok "Prometheus reloaded"
    else
      warn "Failed to reload Prometheus. Restart may be required."
    fi
  else
    warn "Monitoring stack is not running. Start it with: strut monitoring deploy"
  fi

  echo
  ok "Stack $stack_name added to monitoring"
  echo
  echo "To add specific service endpoints, edit: $target_file"
  echo "Example:"
  echo "  - targets:"
  echo "      - 'ch-api:8000'"
  echo "      - 'postgres:5432'"
}

# monitoring_remove_target <stack_name>
#
# Removes a stack from Prometheus monitoring by deleting its target file.
# Reloads Prometheus config if the monitoring stack is running.
#
# Args:
#   stack_name — Name of the stack to remove
# Side effects: Deletes prometheus/targets/<stack>.yml, reloads Prometheus
monitoring_remove_target() {
  local stack_name="$1"

  if [ -z "$stack_name" ]; then
    fail "Usage: monitoring remove-target <stack-name>"
  fi

  local target_file="$MONITORING_STACK_DIR/prometheus/targets/${stack_name}.yml"

  if [ ! -f "$target_file" ]; then
    fail "Target file not found: $target_file"
  fi

  log "Removing $stack_name from monitoring targets..."

  rm "$target_file" || fail "Failed to remove target file"

  ok "Target file removed: $target_file"

  # Reload Prometheus if running
  if monitoring_is_running; then
    log "Reloading Prometheus configuration..."
    docker exec prometheus kill -HUP 1 2>/dev/null
    ok "Prometheus reloaded"
  fi

  ok "Stack $stack_name removed from monitoring"
}

# monitoring_alert_channel_add <channel_type> [options...]
#
# Dispatches alert channel configuration to the appropriate handler
# based on channel type.
#
# Args:
#   channel_type — One of: email, slack, webhook
monitoring_alert_channel_add() {
  local channel_type="$1"
  shift

  if [ -z "$channel_type" ]; then
    fail "Usage: monitoring alert-channel add <email|slack|webhook> [options]"
  fi

  case "$channel_type" in
    email)
      monitoring_alert_channel_add_email "$@"
      ;;
    slack)
      monitoring_alert_channel_add_slack "$@"
      ;;
    webhook)
      monitoring_alert_channel_add_webhook "$@"
      ;;
    *)
      fail "Unknown channel type: $channel_type. Supported: email, slack, webhook"
      ;;
  esac
}

# monitoring_alert_channel_add_email [--to <email>] [--from <email>] [--resend-api-key <key>]
#
# Configures email alerts via Resend SMTP. Updates the monitoring .env file
# and restarts Alertmanager if running.
#
# Args:
#   --to             — Recipient email address
#   --from           — Sender email address
#   --resend-api-key — Resend API key
# Side effects: Modifies .env, restarts Alertmanager
monitoring_alert_channel_add_email() {
  log "Configuring email alert channel (Resend SMTP)..."

  local env_file="$MONITORING_STACK_DIR/.env"

  if [ ! -f "$env_file" ]; then
    fail ".env file not found: $env_file"
  fi

  # Parse command-line arguments
  local to_email=""
  local from_email=""
  local api_key=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --to)
        to_email="$2"
        shift 2
        ;;
      --from)
        from_email="$2"
        shift 2
        ;;
      --resend-api-key)
        api_key="$2"
        shift 2
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done

  # Prompt for missing values
  if [ -z "$to_email" ]; then
    read -p "Alert recipient email: " to_email
  fi

  if [ -z "$from_email" ]; then
    read -p "Alert sender email (or onboarding@resend.dev): " from_email
  fi

  if [ -z "$api_key" ]; then
    read -p "Resend API key: " api_key
  fi

  # Update .env file
  log "Updating .env file..."

  # Use sed to update or add variables
  if grep -q "^ALERT_EMAIL_TO=" "$env_file"; then
    sed -i "s|^ALERT_EMAIL_TO=.*|ALERT_EMAIL_TO=$to_email|" "$env_file"
  else
    echo "ALERT_EMAIL_TO=$to_email" >> "$env_file"
  fi

  if grep -q "^ALERT_EMAIL_FROM=" "$env_file"; then
    sed -i "s|^ALERT_EMAIL_FROM=.*|ALERT_EMAIL_FROM=$from_email|" "$env_file"
  else
    echo "ALERT_EMAIL_FROM=$from_email" >> "$env_file"
  fi

  if grep -q "^RESEND_API_KEY=" "$env_file"; then
    sed -i "s|^RESEND_API_KEY=.*|RESEND_API_KEY=$api_key|" "$env_file"
  else
    echo "RESEND_API_KEY=$api_key" >> "$env_file"
  fi

  if grep -q "^ALERT_EMAIL_ENABLED=" "$env_file"; then
    sed -i "s|^ALERT_EMAIL_ENABLED=.*|ALERT_EMAIL_ENABLED=true|" "$env_file"
  else
    echo "ALERT_EMAIL_ENABLED=true" >> "$env_file"
  fi

  ok "Email alert channel configured"

  # Restart Alertmanager if running
  if docker ps | grep -q alertmanager; then
    log "Restarting Alertmanager..."
    docker-compose -f "$MONITORING_STACK_DIR/docker-compose.yml" restart alertmanager
    ok "Alertmanager restarted"
  fi

  echo
  ok "Email alerts configured successfully!"
  echo
  echo "Configuration:"
  echo "  To:   $to_email"
  echo "  From: $from_email"
  echo
  echo "Test the configuration: strut monitoring alert-channel test email"
}

# monitoring_alert_channel_add_slack [--webhook-url <url>]
#
# Configures Slack alerts via incoming webhook. Updates the monitoring .env
# file and restarts Alertmanager if running.
#
# Args:
#   --webhook-url — Slack incoming webhook URL
# Side effects: Modifies .env, restarts Alertmanager
monitoring_alert_channel_add_slack() {
  log "Configuring Slack alert channel..."

  local env_file="$MONITORING_STACK_DIR/.env"
  local webhook_url=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --webhook-url)
        webhook_url="$2"
        shift 2
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done

  if [ -z "$webhook_url" ]; then
    read -p "Slack webhook URL: " webhook_url
  fi

  # Update .env file
  if grep -q "^SLACK_WEBHOOK_URL=" "$env_file"; then
    sed -i "s|^SLACK_WEBHOOK_URL=.*|SLACK_WEBHOOK_URL=$webhook_url|" "$env_file"
  else
    echo "SLACK_WEBHOOK_URL=$webhook_url" >> "$env_file"
  fi

  if grep -q "^ALERT_SLACK_ENABLED=" "$env_file"; then
    sed -i "s|^ALERT_SLACK_ENABLED=.*|ALERT_SLACK_ENABLED=true|" "$env_file"
  else
    echo "ALERT_SLACK_ENABLED=true" >> "$env_file"
  fi

  ok "Slack alert channel configured"

  # Restart Alertmanager if running
  if docker ps | grep -q alertmanager; then
    log "Restarting Alertmanager..."
    docker-compose -f "$MONITORING_STACK_DIR/docker-compose.yml" restart alertmanager
    ok "Alertmanager restarted"
  fi

  ok "Slack alerts configured successfully!"
}

# monitoring_alert_channel_add_webhook [--url <url>]
#
# Configures a generic webhook alert channel. Updates the monitoring .env
# file and restarts Alertmanager if running.
#
# Args:
#   --url — Webhook endpoint URL
# Side effects: Modifies .env, restarts Alertmanager
monitoring_alert_channel_add_webhook() {
  log "Configuring webhook alert channel..."

  local env_file="$MONITORING_STACK_DIR/.env"
  local webhook_url=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --url)
        webhook_url="$2"
        shift 2
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done

  if [ -z "$webhook_url" ]; then
    read -p "Webhook URL: " webhook_url
  fi

  # Update .env file
  if grep -q "^ALERT_WEBHOOK_URL=" "$env_file"; then
    sed -i "s|^ALERT_WEBHOOK_URL=.*|ALERT_WEBHOOK_URL=$webhook_url|" "$env_file"
  else
    echo "ALERT_WEBHOOK_URL=$webhook_url" >> "$env_file"
  fi

  if grep -q "^ALERT_WEBHOOK_ENABLED=" "$env_file"; then
    sed -i "s|^ALERT_WEBHOOK_ENABLED=.*|ALERT_WEBHOOK_ENABLED=true|" "$env_file"
  else
    echo "ALERT_WEBHOOK_ENABLED=true" >> "$env_file"
  fi

  ok "Webhook alert channel configured"

  # Restart Alertmanager if running
  if docker ps | grep -q alertmanager; then
    log "Restarting Alertmanager..."
    docker-compose -f "$MONITORING_STACK_DIR/docker-compose.yml" restart alertmanager
    ok "Alertmanager restarted"
  fi

  ok "Webhook alerts configured successfully!"
}

# monitoring_alert_channel_test [channel_type]
#
# Sends a test alert through Alertmanager to verify channel configuration.
#
# Args:
#   channel_type — Channel to test (default: "email")
# Returns: 0 on success, 1 if monitoring stack is not running or send fails
monitoring_alert_channel_test() {
  local channel_type="${1:-email}"

  if ! monitoring_is_running; then
    fail "Monitoring stack is not running. Start it with: strut monitoring deploy"
  fi

  log "Sending test alert to $channel_type channel..."

  # Create test alert
  local test_alert=$(cat <<EOF
[{
  "labels": {
    "alertname": "TestAlert",
    "severity": "warning",
    "stack": "monitoring",
    "instance": "test",
    "service": "strut"
  },
  "annotations": {
    "summary": "Test alert from strut monitoring",
    "description": "This is a test alert to verify your alert channel configuration. If you receive this, your alerts are working correctly!"
  },
  "startsAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "endsAt": "$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
}]
EOF
)

  # Load monitoring services config
  local monitoring_conf="$MONITORING_STACK_DIR/services.conf"
  # shellcheck disable=SC1090
  [ -f "$monitoring_conf" ] && source "$monitoring_conf"
  local alertmanager_port="${ALERTMANAGER_PORT:-9093}"

  # Send alert to Alertmanager
  if curl -s -X POST -H "Content-Type: application/json" \
      -d "$test_alert" \
      "http://localhost:${alertmanager_port}/api/v2/alerts" > /dev/null 2>&1; then
    ok "Test alert sent successfully!"
    echo
    echo "Check your $channel_type for the test alert."
    echo "Note: It may take 1-2 minutes to arrive."
  else
    fail "Failed to send test alert"
  fi
}

# monitoring_status [format]
#
# Displays the status of all monitoring services and their access endpoints.
#
# Args:
#   format — Output format: "text" (default) or "json"
monitoring_status() {
  local format="${1:-text}"

  log "Checking monitoring stack status..."
  echo

  # Check if services are running
  local prometheus_status="down"
  local grafana_status="down"
  local alertmanager_status="down"
  local node_exporter_status="down"
  local cadvisor_status="down"

  if docker ps | grep -q prometheus; then
    prometheus_status="up"
  fi

  if docker ps | grep -q grafana; then
    grafana_status="up"
  fi

  if docker ps | grep -q alertmanager; then
    alertmanager_status="up"
  fi

  if docker ps | grep -q node-exporter; then
    node_exporter_status="up"
  fi

  if docker ps | grep -q cadvisor; then
    cadvisor_status="up"
  fi

  if [ "$format" = "json" ]; then
    # JSON output
    cat <<EOF
{
  "status": "$([ "$prometheus_status" = "up" ] && [ "$grafana_status" = "up" ] && [ "$alertmanager_status" = "up" ] && echo "healthy" || echo "unhealthy")",
  "services": {
    "prometheus": "$prometheus_status",
    "grafana": "$grafana_status",
    "alertmanager": "$alertmanager_status",
    "node_exporter": "$node_exporter_status",
    "cadvisor": "$cadvisor_status"
  }
}
EOF
  else
    # Text output
    echo "Service Status:"
    echo "  Prometheus:    $prometheus_status"
    echo "  Grafana:       $grafana_status"
    echo "  Alertmanager:  $alertmanager_status"
    echo "  Node Exporter: $node_exporter_status"
    echo "  cAdvisor:      $cadvisor_status"
    echo

    if monitoring_is_running; then
      ok "Monitoring stack is healthy"
      echo

      # Load monitoring services config for display
      local monitoring_conf="$MONITORING_STACK_DIR/services.conf"
      # shellcheck disable=SC1090
      [ -f "$monitoring_conf" ] && source "$monitoring_conf"
      local prometheus_port="${PROMETHEUS_PORT:-9090}"
      local grafana_port="${GRAFANA_PORT:-3000}"
      local alertmanager_port="${ALERTMANAGER_PORT:-9093}"

      echo "Access points:"
      echo "  Prometheus:   http://localhost:${prometheus_port}"
      echo "  Grafana:      http://localhost:${grafana_port}"
      echo "  Alertmanager: http://localhost:${alertmanager_port}"
    else
      warn "Monitoring stack is not fully running"
      echo
      echo "Start the monitoring stack: strut monitoring deploy"
    fi
  fi
}
