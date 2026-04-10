---
name: monitoring-setup
description: Set up and manage self-hosted monitoring with Prometheus, Grafana, and Alertmanager for strut stacks. Use when deploying monitoring, configuring alerts, setting up cross-VPS monitoring, or creating dashboards.
---

# Monitoring Setup

Procedures for deploying and managing self-hosted monitoring infrastructure (Prometheus, Grafana, Alertmanager) for strut stacks.

## Quick Reference

```bash
# Deploy monitoring stack
strut monitoring deploy --env prod

# Add a stack to monitoring
strut monitoring add-target my-stack --env prod

# Configure email alerts (Resend SMTP)
strut monitoring alert-channel add email \
  --to alerts@yourdomain.com \
  --from monitoring@yourdomain.com \
  --resend-api-key re_xxx

# Test alert delivery
strut monitoring alert-channel test email

# Check monitoring status
strut monitoring status

# Reload Prometheus config
strut monitoring reload
```

## Architecture

### Components

| Component | Purpose | Default Port |
|-----------|---------|-------------|
| Prometheus | Metrics collection, time-series DB, alert rule evaluation | 9090 |
| Grafana | Dashboards and visualization | 3000 |
| Alertmanager | Alert routing, grouping, notifications | 9093 |
| Node Exporter | System metrics (CPU, memory, disk, network) | 9100 |
| cAdvisor | Per-container resource metrics | 8080 |

### Deployment Strategy

Monitoring runs on VPS-1 (my-stack VPS) and monitors:
- Local stacks via localhost
- Remote stacks via SSH tunnels or exposed metrics endpoints

## Installation

### Step 1: Deploy

```bash
strut monitoring deploy --env prod
```

### Step 2: Configure Environment

Edit `.monitoring-prod.env`:
```bash
# Resend SMTP for email alerts
RESEND_API_KEY=re_xxx
ALERT_EMAIL_TO=alerts@yourdomain.com
ALERT_EMAIL_FROM=monitoring@yourdomain.com

# Optional: Slack webhook
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/xxx

# Grafana credentials
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<secure-password>
```

### Step 3: Add Stacks

```bash
strut monitoring add-target my-stack --env prod
strut monitoring add-target twenty --env prod
strut monitoring add-target twenty-mcp --env prod
```

### Step 4: Access Grafana

Open `http://<vps-ip>:3000` and login with credentials from `.monitoring-prod.env`.

## Alert Channels

### Email (Resend SMTP) — Primary

1. Sign up at https://resend.com, create API key (free tier: 100 emails/day)
2. Configure:
   ```bash
   strut monitoring alert-channel add email \
     --to alerts@yourdomain.com \
     --from monitoring@yourdomain.com \
     --resend-api-key re_xxx
   ```
3. Test: `strut monitoring alert-channel test email`

SMTP config: `smtp.resend.com:587`, username=`resend`, password=API_KEY, TLS required.

### Slack — Secondary

1. Create Slack app → Enable Incoming Webhooks → Copy URL
2. Configure:
   ```bash
   strut monitoring alert-channel add slack \
     --webhook-url https://hooks.slack.com/services/xxx
   ```
3. Test: `strut monitoring alert-channel test slack`

### Generic Webhooks

```bash
strut monitoring alert-channel add webhook \
  --url https://your-service.com/alerts --method POST
```

### Alert Routing by Severity

```bash
# Critical → email + Slack
strut monitoring alert-route critical email,slack

# Warning → email only
strut monitoring alert-route warning email

# Info → Slack only
strut monitoring alert-route info slack
```

### Alert Severity Levels

| Severity | Triggers | Examples |
|----------|----------|---------|
| Critical | Immediate action required | Service down, DB unreachable, disk >95% |
| Warning | Attention needed soon | CPU >80% for 5min, memory >90%, disk >85% |
| Info | Informational | Backup completed, deployment successful, drift detected |

## Default Alert Rules

```yaml
# Service down for 2+ minutes
alert: ServiceDown
expr: up == 0
for: 2m
severity: critical

# CPU >80% for 5+ minutes
alert: HighCPU
expr: rate(node_cpu_seconds_total[5m]) > 0.8
for: 5m
severity: warning

# Memory >90% for 5+ minutes
alert: HighMemory
expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes > 0.9
for: 5m
severity: warning

# Disk <15% free for 5+ minutes
alert: DiskSpaceLow
expr: (node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.15
for: 5m
severity: warning
```

### Custom Alert Rules

Create `stacks/monitoring/prometheus/alerts/custom.yml`:
```yaml
groups:
  - name: custom_alerts
    rules:
      - alert: HighErrorRate
        expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate detected"
```

Reload: `strut monitoring reload`

## Pre-configured Dashboards

- Stack Overview — all stacks at a glance (health, resources, alerts, uptime)
- Stack Health — per-stack service availability, response times, error rates
- Resource Usage — CPU/memory/disk/network per service with trends
- Backup Status — success rate, last backup time, verification, storage

## Cross-VPS Monitoring

### Setup Node Exporter on Remote VPS

```bash
ssh ubuntu@<remote-vps>

# Node Exporter
docker run -d --name node-exporter --restart unless-stopped \
  -p 9100:9100 prom/node-exporter

# cAdvisor
docker run -d --name cadvisor --restart unless-stopped \
  -p 8080:8080 \
  -v /:/rootfs:ro -v /var/run:/var/run:ro \
  -v /sys:/sys:ro -v /var/lib/docker/:/var/lib/docker:ro \
  gcr.io/cadvisor/cadvisor
```

### Option A: SSH Tunnel (Recommended)

```bash
# Persistent tunnel from monitoring VPS to remote VPS
ssh -L 9100:localhost:9100 -L 8080:localhost:8080 ubuntu@<remote-vps> -N -f

# For persistence, use autossh:
autossh -M 0 -f -N \
  -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" \
  -L 9100:localhost:9100 ubuntu@<remote-vps>
```

### Option B: Expose Metrics Ports (Less Secure)

```bash
# On remote VPS — allow only monitoring VPS IP
sudo ufw allow from <monitoring-vps-ip> to any port 9100
sudo ufw allow from <monitoring-vps-ip> to any port 8080
```

### Add Remote Stack

```bash
strut monitoring add-target twenty --env prod --vps vps-2
```

## Maintenance

```bash
# Update monitoring images
strut monitoring update --env prod

# Restart services
strut monitoring restart --env prod

# Backup Prometheus data
strut monitoring backup prometheus --env prod

# Backup Grafana dashboards
strut monitoring backup grafana --env prod
```

Prometheus auto-removes metrics older than 30 days. Change retention:
```yaml
# In docker-compose.yml, add to prometheus command:
--storage.tsdb.retention.time=90d
```

## Troubleshooting

### Prometheus Not Scraping
```bash
# Check targets: http://<vps-ip>:9090/targets
curl http://localhost:9100/metrics   # Node Exporter
curl http://localhost:8080/metrics   # cAdvisor
strut monitoring logs prometheus --follow
```

### Grafana Dashboards Not Loading
```bash
strut monitoring logs grafana --follow
# Check Grafana → Configuration → Data Sources → Test connection
strut monitoring provision-dashboards
```

### Alerts Not Sending
```bash
# Check Alertmanager: http://<vps-ip>:9093
strut monitoring logs alertmanager --follow
strut monitoring alert-channel test email
```

## Security Considerations

1. Use strong Grafana admin password
2. Don't expose metrics endpoints publicly
3. Use SSH tunnels for cross-VPS (not open ports)
4. Restrict metrics ports to monitoring VPS IP via firewall
5. Secure webhook URLs and API keys
6. Consider data privacy for stored metrics

## Related Documentation

- `strut/stacks/monitoring/README.md` — Stack-specific docs
- `strut/stacks/monitoring/RESEND_SETUP.md` — Resend email setup
- `strut/stacks/monitoring/CROSS_VPS_MONITORING.md` — Multi-VPS details
- `#drift-detection` — Drift alerts integrate with monitoring
- `#database-backups` — Backup health monitoring
- `#vps-debugging` — Debug services flagged by alerts
