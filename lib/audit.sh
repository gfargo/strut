#!/usr/bin/env bash
# ==================================================
# audit.sh — VPS audit and stack discovery
# ==================================================
#
# Functions for auditing existing Docker setups on VPS
# and generating strut stack definitions

# Helper function for yes/no prompts (accepts yes/y/no/n)
# Only define if not already defined (migrate.sh may define it first)
set -euo pipefail

if ! declare -f confirm &>/dev/null; then
  confirm() {
    local prompt="${1:-Continue?}"
    read -p "$prompt (yes/no): " -r
    # Trim whitespace from reply
    REPLY=$(echo "$REPLY" | xargs)
    [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]
  }
fi

# ── Audit sub-functions ───────────────────────────────────────────────────────
# Each _audit_* function collects one category of information from the VPS.
# All receive: ssh_opts, vps_user, vps_host, _sudo, audit_dir

# _audit_docker <ssh_opts> <vps_user> <vps_host> <_sudo> <audit_dir>
# Collects Docker containers, volumes, networks, images, ports, disk usage
_audit_docker() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" _sudo="$4" audit_dir="$5"

  log "Collecting container information..."

  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker ps --format '{{json .}}'" > "$audit_dir/containers.jsonl" 2>/dev/null || {
    warn "Failed to get container list. Is Docker running?"
    return 1
  }
  log "  ✓ Containers collected"

  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker ps -a --format '{{json .}}'" > "$audit_dir/containers-all.jsonl" 2>/dev/null
  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker volume ls --format '{{json .}}'" > "$audit_dir/volumes.jsonl" 2>/dev/null
  log "  ✓ Volumes collected"

  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker network ls --format '{{json .}}'" > "$audit_dir/networks.jsonl" 2>/dev/null
  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker images --format '{{json .}}'" > "$audit_dir/images.jsonl" 2>/dev/null
  log "  ✓ Images collected"

  ssh $ssh_opts "$vps_user@$vps_host" "ss -tuln | grep LISTEN" > "$audit_dir/ports.txt" 2>/dev/null
  ssh $ssh_opts "$vps_user@$vps_host" "df -h" > "$audit_dir/disk-usage.txt" 2>/dev/null
  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker system df -v" > "$audit_dir/docker-disk-usage.txt" 2>/dev/null
  log "  ✓ Disk usage collected"

  ssh $ssh_opts "$vps_user@$vps_host" "timeout 10 find /home /opt -maxdepth 5 -name 'docker-compose.yml' -o -name 'docker-compose.yaml' 2>/dev/null" > "$audit_dir/compose-files.txt" 2>/dev/null || true
  log "  ✓ Compose files found"
}

# _audit_nginx <ssh_opts> <vps_user> <vps_host> <_sudo> <audit_dir>
# Collects nginx configuration from containers and system service
_audit_nginx() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" _sudo="$4" audit_dir="$5"

  log "Collecting nginx configuration..."
  mkdir -p "$audit_dir/nginx"

  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker ps --format '{{.Names}}' | grep -i nginx" > "$audit_dir/nginx/nginx-containers.txt" 2>/dev/null || true
  ssh $ssh_opts "$vps_user@$vps_host" "systemctl is-active nginx 2>/dev/null || echo 'not-running'" > "$audit_dir/nginx/nginx-service-status.txt" 2>/dev/null || true

  local nginx_containers
  nginx_containers=$(cat "$audit_dir/nginx/nginx-containers.txt" 2>/dev/null)
  if [ -n "$nginx_containers" ]; then
    for nginx_container in $nginx_containers; do
      log "  Extracting nginx config from container: $nginx_container"
      ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker exec $nginx_container cat /etc/nginx/nginx.conf 2>/dev/null" > "$audit_dir/nginx/${nginx_container}-nginx.conf" 2>/dev/null || true
      ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker exec $nginx_container find /etc/nginx/conf.d -name '*.conf' -exec cat {} \; 2>/dev/null" > "$audit_dir/nginx/${nginx_container}-conf.d.txt" 2>/dev/null || true
      ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker exec $nginx_container ls -la /etc/nginx/ssl 2>/dev/null" > "$audit_dir/nginx/${nginx_container}-ssl-certs.txt" 2>/dev/null || true
    done
  fi

  if grep -q "active" "$audit_dir/nginx/nginx-service-status.txt" 2>/dev/null; then
    log "  Extracting system nginx config"
    ssh $ssh_opts "$vps_user@$vps_host" "sudo cat /etc/nginx/nginx.conf 2>/dev/null" > "$audit_dir/nginx/system-nginx.conf" 2>/dev/null || true
    ssh $ssh_opts "$vps_user@$vps_host" "sudo find /etc/nginx/sites-enabled -name '*.conf' -o -name '*[!.conf]' 2>/dev/null | xargs sudo cat 2>/dev/null" > "$audit_dir/nginx/system-sites-enabled.txt" 2>/dev/null || true
    ssh $ssh_opts "$vps_user@$vps_host" "sudo ls -la /etc/letsencrypt/live 2>/dev/null" > "$audit_dir/nginx/system-ssl-certs.txt" 2>/dev/null || true
  fi
  log "  ✓ Nginx configuration collected"
}

# _audit_systemd <ssh_opts> <vps_user> <vps_host> <audit_dir>
# Collects systemd service information
_audit_systemd() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" audit_dir="$4"

  log "Collecting systemd services..."
  mkdir -p "$audit_dir/systemd"

  ssh $ssh_opts "$vps_user@$vps_host" "systemctl list-units --type=service --state=running --no-pager" > "$audit_dir/systemd/running-services.txt" 2>/dev/null || true
  ssh $ssh_opts "$vps_user@$vps_host" "systemctl list-unit-files --type=service --state=enabled --no-pager" > "$audit_dir/systemd/enabled-services.txt" 2>/dev/null || true
  ssh $ssh_opts "$vps_user@$vps_host" "systemctl list-units --type=service --state=running --no-pager | grep -v -E '(systemd|dbus|cron|ssh|network|udev|getty|user@)' | awk '{print \$1}'" > "$audit_dir/systemd/custom-services.txt" 2>/dev/null || true

  if [ -s "$audit_dir/systemd/custom-services.txt" ]; then
    while IFS= read -r service; do
      [ -z "$service" ] && continue
      local safe_service_name
      safe_service_name=$(echo "$service" | tr '/' '_' | tr '@' '_')
      ssh $ssh_opts "$vps_user@$vps_host" "systemctl status $service --no-pager 2>/dev/null" > "$audit_dir/systemd/${safe_service_name}-status.txt" 2>/dev/null || true
      ssh $ssh_opts "$vps_user@$vps_host" "systemctl cat $service 2>/dev/null" > "$audit_dir/systemd/${safe_service_name}-unit.txt" 2>/dev/null || true
    done < "$audit_dir/systemd/custom-services.txt"
  fi
  log "  ✓ Systemd services collected"
}

# _audit_cron <ssh_opts> <vps_user> <vps_host> <audit_dir>
# Collects cron job information
_audit_cron() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" audit_dir="$4"

  log "Collecting cron jobs..."
  mkdir -p "$audit_dir/cron"

  ssh $ssh_opts "$vps_user@$vps_host" "crontab -l 2>/dev/null" > "$audit_dir/cron/user-crontab.txt" 2>/dev/null || echo "No user crontab" > "$audit_dir/cron/user-crontab.txt"
  ssh $ssh_opts "$vps_user@$vps_host" "sudo ls -la /etc/cron.d/ 2>/dev/null" > "$audit_dir/cron/cron.d-list.txt" 2>/dev/null || true
  ssh $ssh_opts "$vps_user@$vps_host" "sudo cat /etc/cron.d/* 2>/dev/null" > "$audit_dir/cron/cron.d-contents.txt" 2>/dev/null || true
  log "  ✓ Cron jobs collected"
}

# _audit_firewall <ssh_opts> <vps_user> <vps_host> <audit_dir>
# Collects firewall rules (UFW + iptables)
_audit_firewall() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" audit_dir="$4"

  log "Collecting firewall configuration..."
  mkdir -p "$audit_dir/firewall"

  ssh $ssh_opts "$vps_user@$vps_host" "sudo ufw status verbose 2>/dev/null" > "$audit_dir/firewall/ufw-status.txt" 2>/dev/null || echo "UFW not installed or not active" > "$audit_dir/firewall/ufw-status.txt"
  ssh $ssh_opts "$vps_user@$vps_host" "sudo iptables -L -n -v 2>/dev/null" > "$audit_dir/firewall/iptables-rules.txt" 2>/dev/null || true
}

# _audit_ssl <ssh_opts> <vps_user> <vps_host> <audit_dir>
# Collects SSL certificate information
_audit_ssl() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" audit_dir="$4"

  log "Collecting SSL certificate information..."
  mkdir -p "$audit_dir/ssl"

  ssh $ssh_opts "$vps_user@$vps_host" "sudo certbot certificates 2>/dev/null" > "$audit_dir/ssl/certbot-certificates.txt" 2>/dev/null || echo "Certbot not installed" > "$audit_dir/ssl/certbot-certificates.txt"
  ssh $ssh_opts "$vps_user@$vps_host" "sudo find /etc/letsencrypt/live -type l 2>/dev/null" > "$audit_dir/ssl/letsencrypt-certs.txt" 2>/dev/null || true
  ssh $ssh_opts "$vps_user@$vps_host" "sudo find /etc/ssl/certs -name '*.pem' -o -name '*.crt' 2>/dev/null | head -20" > "$audit_dir/ssl/system-certs.txt" 2>/dev/null || true
}

# _audit_secrets <ssh_opts> <vps_user> <vps_host> <_sudo> <audit_dir>
# Collects environment variable patterns (keys only, not values)
_audit_secrets() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" _sudo="$4" audit_dir="$5"

  log "Collecting environment variable patterns..."
  mkdir -p "$audit_dir/secrets"

  ssh $ssh_opts "$vps_user@$vps_host" "find /home /opt -maxdepth 5 -name '.env' -o -name '*.env' 2>/dev/null" > "$audit_dir/secrets/env-files.txt" 2>/dev/null || true

  local container_ids
  container_ids=$(ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker ps -q" 2>/dev/null || echo "")
  if [ -n "$container_ids" ]; then
    for cid in $container_ids; do
      ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker inspect $cid --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | cut -d'=' -f1 | sort -u" > "$audit_dir/secrets/container-${cid}-env-keys.txt" 2>/dev/null || true
    done
  fi
  log "  ✓ Environment patterns collected"
}

# _audit_databases <ssh_opts> <vps_user> <vps_host> <_sudo> <audit_dir>
# Detects database services (containers, system services, ports)
_audit_databases() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" _sudo="$4" audit_dir="$5"

  log "Detecting database services..."
  mkdir -p "$audit_dir/databases"

  ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker ps --format '{{.Names}}\t{{.Image}}' | grep -E '(postgres|mysql|mariadb|mongo|redis|neo4j)'" > "$audit_dir/databases/database-containers.txt" 2>/dev/null || echo "No database containers found" > "$audit_dir/databases/database-containers.txt"
  ssh $ssh_opts "$vps_user@$vps_host" "systemctl list-units --type=service --state=running --no-pager | grep -E '(postgres|mysql|mariadb|mongo|redis)'" > "$audit_dir/databases/database-services.txt" 2>/dev/null || echo "No database system services found" > "$audit_dir/databases/database-services.txt"
  ssh $ssh_opts "$vps_user@$vps_host" "ss -tuln | grep -E ':(5432|3306|27017|6379|7687)'" > "$audit_dir/databases/database-ports.txt" 2>/dev/null || echo "No database ports detected" > "$audit_dir/databases/database-ports.txt"
}

# _audit_keys <audit_dir>
# Categorizes discovered env keys from the secrets collection phase
_audit_keys() {
  local audit_dir="$1"

  log "Running keys discovery..."
  mkdir -p "$audit_dir/keys"

  cat > "$audit_dir/keys/discovered-env-keys.json" <<'EOF'
{
  "discovered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "env_keys": []
}
EOF

  # Collect unique env var keys from all container secret files
  local all_env_keys=()
  for keyfile in "$audit_dir"/secrets/container-*-env-keys.txt; do
    [ -f "$keyfile" ] || continue
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      all_env_keys+=("$key")
    done < "$keyfile"
  done

  if [ ${#all_env_keys[@]} -gt 0 ]; then
    printf '%s\n' "${all_env_keys[@]}" | sort -u > "$audit_dir/keys/all-env-keys.txt"
  fi

  cat > "$audit_dir/keys/key-categories.json" <<'EOF'
{
  "database_keys": [],
  "api_keys": [],
  "auth_keys": [],
  "service_keys": [],
  "unknown_keys": []
}
EOF

  if [ -f "$audit_dir/keys/all-env-keys.txt" ]; then
    grep -iE '(DATABASE|DB|POSTGRES|MYSQL|MONGO|REDIS|NEO4J)' "$audit_dir/keys/all-env-keys.txt" > "$audit_dir/keys/database-keys.txt" 2>/dev/null || touch "$audit_dir/keys/database-keys.txt"
    grep -iE '(API_KEY|APIKEY|API_SECRET|TOKEN)' "$audit_dir/keys/all-env-keys.txt" > "$audit_dir/keys/api-keys.txt" 2>/dev/null || touch "$audit_dir/keys/api-keys.txt"
    grep -iE '(SECRET|PASSWORD|PASS|AUTH|JWT|SESSION)' "$audit_dir/keys/all-env-keys.txt" > "$audit_dir/keys/auth-keys.txt" 2>/dev/null || touch "$audit_dir/keys/auth-keys.txt"
    grep -iE '(SMTP|EMAIL|TWILIO|AWS|GCP|AZURE|GITHUB|GITLAB)' "$audit_dir/keys/all-env-keys.txt" > "$audit_dir/keys/service-keys.txt" 2>/dev/null || touch "$audit_dir/keys/service-keys.txt"
  fi

  _audit_keys_migration_template "$audit_dir"
  log "  ✓ Keys discovery complete"
}

# _audit_keys_migration_template <audit_dir>
# Generates the KEYS_MIGRATION.md guide
_audit_keys_migration_template() {
  local audit_dir="$1"

  cat > "$audit_dir/keys/KEYS_MIGRATION.md" <<'EOF'
# Keys Migration Guide

This audit discovered environment variables that need to be migrated to strut.

## Discovered Keys

See `all-env-keys.txt` for complete list of environment variable keys found in containers.

## Key Categories

- **Database Keys**: `database-keys.txt` - Database connection strings, credentials
- **API Keys**: `api-keys.txt` - External service API keys
- **Auth Keys**: `auth-keys.txt` - Authentication secrets, passwords, JWT keys
- **Service Keys**: `service-keys.txt` - Third-party service credentials

## Migration Steps

1. Review keys: `cat keys/all-env-keys.txt`
2. Extract values from original containers: `docker exec <container> env | grep KEY`
3. Add to stack `.env.template`
4. Optionally use strut keys management: `strut <stack> keys discover`

## Security Notes

- This audit does NOT capture secret values (only key names)
- Never commit .env files with secrets to git
- Use strut's keys system for production secret management
EOF
}

# _audit_containers <ssh_opts> <vps_user> <vps_host> <_sudo> <audit_dir>
# Collects detailed container inspections and compose configs
_audit_containers() {
  local ssh_opts="$1" vps_user="$2" vps_host="$3" _sudo="$4" audit_dir="$5"

  log "Collecting detailed container information..."
  local container_ids
  container_ids=$(ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker ps -q" 2>/dev/null)

  if [ -n "$container_ids" ]; then
    mkdir -p "$audit_dir/containers"
    for cid in $container_ids; do
      ssh $ssh_opts "$vps_user@$vps_host" "${_sudo}docker inspect $cid" > "$audit_dir/containers/$cid.json" 2>/dev/null
    done
  fi

  if [ -s "$audit_dir/compose-files.txt" ]; then
    log "Collecting docker-compose configurations..."
    mkdir -p "$audit_dir/compose-configs"
    local idx=0
    local total
    total=$(wc -l < "$audit_dir/compose-files.txt")
    while IFS= read -r compose_file; do
      [ -z "$compose_file" ] && continue
      idx=$((idx + 1))
      log "  Processing compose file $idx/$total: $compose_file"
      local compose_dir
      compose_dir=$(dirname "$compose_file")
      local safe_name
      safe_name=$(echo "$compose_file" | tr '/' '_')
      ssh $ssh_opts "$vps_user@$vps_host" "cd '$compose_dir' && timeout 5 ${_sudo}docker compose config 2>/dev/null || timeout 5 ${_sudo}docker-compose config 2>/dev/null" > "$audit_dir/compose-configs/$safe_name.yml" 2>/dev/null || true
    done < "$audit_dir/compose-files.txt"
    log "  ✓ Docker-compose configurations collected"
  fi
}

# ── Main orchestrator ─────────────────────────────────────────────────────────

# audit_vps <vps_host> <vps_user> [ssh_key] [ssh_port]
# Connects to VPS and audits all running Docker containers.
# Delegates to _audit_* sub-functions for each category.
audit_vps() {
  local vps_host="$1"
  local vps_user="${2:-ubuntu}"
  local ssh_key="${3:-}"
  local ssh_port="${4:-}"

  [ -n "$vps_host" ] || fail "Usage: audit_vps <vps_host> [vps_user] [ssh_key] [ssh_port]"

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$ssh_port" -k "$ssh_key")

  local _sudo
  _sudo="$(vps_sudo_prefix)"

  log "Auditing VPS: $vps_user@$vps_host"
  [ -n "$_sudo" ] && log "  (using sudo for docker commands)"

  local audit_dir="$CLI_ROOT/audits/$(date +%Y%m%d-%H%M%S)-$vps_host"
  mkdir -p "$audit_dir"

  # Run each audit category
  _audit_docker   "$ssh_opts" "$vps_user" "$vps_host" "$_sudo" "$audit_dir"
  _audit_nginx    "$ssh_opts" "$vps_user" "$vps_host" "$_sudo" "$audit_dir"
  _audit_systemd  "$ssh_opts" "$vps_user" "$vps_host" "$audit_dir"
  _audit_cron     "$ssh_opts" "$vps_user" "$vps_host" "$audit_dir"
  _audit_firewall "$ssh_opts" "$vps_user" "$vps_host" "$audit_dir"
  _audit_ssl      "$ssh_opts" "$vps_user" "$vps_host" "$audit_dir"
  _audit_secrets  "$ssh_opts" "$vps_user" "$vps_host" "$_sudo" "$audit_dir"
  _audit_databases "$ssh_opts" "$vps_user" "$vps_host" "$_sudo" "$audit_dir"
  _audit_keys     "$audit_dir"
  _audit_containers "$ssh_opts" "$vps_user" "$vps_host" "$_sudo" "$audit_dir"

  ok "Audit complete: $audit_dir"

  # Generate reports
  audit_generate_report "$audit_dir" "$vps_host"
  audit_suggest_stacks "$audit_dir"

  echo ""
  echo -e "${BLUE}Next steps:${NC}"
  echo "  1. Review audit report: cat $audit_dir/REPORT.md"
  echo "  2. Review stack suggestions: cat $audit_dir/STACK_SUGGESTIONS.md"
  echo "  3. Generate stacks: strut audit:generate <stack-name> --from $audit_dir"
  echo ""
}

# audit_generate_report <audit_dir> <vps_host>
# Generates a human-readable markdown report
audit_generate_report() {
  local audit_dir="$1"
  local vps_host="$2"
  local report="$audit_dir/REPORT.md"

  log "Generating audit report..."

  cat > "$report" <<EOF
# VPS Audit Report

**VPS:** $vps_host
**Date:** $(date)
**Audit Directory:** $audit_dir

---

## Summary

EOF

  # Count containers
  local running_count
  running_count=$(wc -l < "$audit_dir/containers.jsonl" 2>/dev/null || echo "0")
  local total_count
  total_count=$(wc -l < "$audit_dir/containers-all.jsonl" 2>/dev/null || echo "0")

  cat >> "$report" <<EOF
- **Running Containers:** $running_count
- **Total Containers:** $total_count
- **Volumes:** $(wc -l < "$audit_dir/volumes.jsonl" 2>/dev/null || echo "0")
- **Networks:** $(wc -l < "$audit_dir/networks.jsonl" 2>/dev/null || echo "0")
- **Images:** $(wc -l < "$audit_dir/images.jsonl" 2>/dev/null || echo "0")

---

## Running Containers

EOF

  # Parse containers.jsonl and format as table
  if [ -s "$audit_dir/containers.jsonl" ]; then
    echo "| Name | Image | Ports | Status |" >> "$report"
    echo "|------|-------|-------|--------|" >> "$report"

    while IFS= read -r line; do
      local name image ports status
      name=$(echo "$line" | jq -r '.Names // "N/A"' 2>/dev/null || echo "N/A")
      image=$(echo "$line" | jq -r '.Image // "N/A"' 2>/dev/null || echo "N/A")
      ports=$(echo "$line" | jq -r '.Ports // "N/A"' 2>/dev/null || echo "N/A")
      status=$(echo "$line" | jq -r '.Status // "N/A"' 2>/dev/null || echo "N/A")
      echo "| $name | $image | $ports | $status |" >> "$report"
    done < "$audit_dir/containers.jsonl"
  else
    echo "No running containers found." >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Volumes

EOF

  if [ -s "$audit_dir/volumes.jsonl" ]; then
    echo "| Name | Driver |" >> "$report"
    echo "|------|--------|" >> "$report"

    while IFS= read -r line; do
      local name driver
      name=$(echo "$line" | jq -r '.Name // "N/A"' 2>/dev/null || echo "N/A")
      driver=$(echo "$line" | jq -r '.Driver // "N/A"' 2>/dev/null || echo "N/A")
      echo "| $name | $driver |" >> "$report"
    done < "$audit_dir/volumes.jsonl"
  else
    echo "No volumes found." >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Port Usage

\`\`\`
$(cat "$audit_dir/ports.txt" 2>/dev/null || echo "No port information available")
\`\`\`

---

## Disk Usage

\`\`\`
$(cat "$audit_dir/disk-usage.txt" 2>/dev/null || echo "No disk usage information available")
\`\`\`

---

## Docker Disk Usage

\`\`\`
$(cat "$audit_dir/docker-disk-usage.txt" 2>/dev/null || echo "No Docker disk usage information available")
\`\`\`

---

## Docker Compose Files Found

EOF

  if [ -s "$audit_dir/compose-files.txt" ]; then
    while IFS= read -r compose_file; do
      echo "- \`$compose_file\`" >> "$report"
    done < "$audit_dir/compose-files.txt"
  else
    echo "No docker-compose files found." >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Nginx Configuration

EOF

  # Nginx containers
  if [ -s "$audit_dir/nginx/nginx-containers.txt" ]; then
    echo "**Nginx Containers:**" >> "$report"
    echo "" >> "$report"
    while IFS= read -r nginx_container; do
      echo "- \`$nginx_container\`" >> "$report"
      if [ -f "$audit_dir/nginx/${nginx_container}-nginx.conf" ]; then
        echo "  - Config: \`nginx/${nginx_container}-nginx.conf\`" >> "$report"
      fi
      if [ -f "$audit_dir/nginx/${nginx_container}-ssl-certs.txt" ]; then
        echo "  - SSL Certs: \`nginx/${nginx_container}-ssl-certs.txt\`" >> "$report"
      fi
    done < "$audit_dir/nginx/nginx-containers.txt"
    echo "" >> "$report"
  fi

  # System nginx
  if [ -f "$audit_dir/nginx/system-nginx.conf" ]; then
    echo "**System Nginx:**" >> "$report"
    echo "" >> "$report"
    echo "- Config: \`nginx/system-nginx.conf\`" >> "$report"
    echo "- Sites: \`nginx/system-sites-enabled.txt\`" >> "$report"
    echo "- SSL: \`nginx/system-ssl-certs.txt\`" >> "$report"
    echo "" >> "$report"
  fi

  if [ ! -s "$audit_dir/nginx/nginx-containers.txt" ] && [ ! -f "$audit_dir/nginx/system-nginx.conf" ]; then
    echo "No nginx configuration found." >> "$report"
    echo "" >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Systemd Services

EOF

  if [ -s "$audit_dir/systemd/custom-services.txt" ]; then
    echo "**Custom Services Running:**" >> "$report"
    echo "" >> "$report"
    while IFS= read -r service; do
      [ -z "$service" ] && continue
      echo "- \`$service\`" >> "$report"
    done < "$audit_dir/systemd/custom-services.txt"
    echo "" >> "$report"
    echo "See \`systemd/\` directory for detailed service configurations." >> "$report"
  else
    echo "No custom systemd services detected (only system services running)." >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Cron Jobs

EOF

  if [ -s "$audit_dir/cron/user-crontab.txt" ] && ! grep -q "No user crontab" "$audit_dir/cron/user-crontab.txt"; then
    echo "**User Crontab:**" >> "$report"
    echo "" >> "$report"
    echo "\`\`\`" >> "$report"
    cat "$audit_dir/cron/user-crontab.txt" >> "$report"
    echo "\`\`\`" >> "$report"
    echo "" >> "$report"
  fi

  if [ -s "$audit_dir/cron/cron.d-contents.txt" ]; then
    echo "**System Cron Jobs (/etc/cron.d):**" >> "$report"
    echo "" >> "$report"
    echo "See \`cron/cron.d-contents.txt\` for details." >> "$report"
    echo "" >> "$report"
  fi

  if [ ! -s "$audit_dir/cron/user-crontab.txt" ] && [ ! -s "$audit_dir/cron/cron.d-contents.txt" ]; then
    echo "No cron jobs found." >> "$report"
    echo "" >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Firewall Configuration

\`\`\`
$(cat "$audit_dir/firewall/ufw-status.txt" 2>/dev/null || echo "No firewall information available")
\`\`\`

See \`firewall/iptables-rules.txt\` for detailed iptables rules.

---

## SSL Certificates

EOF

  if [ -s "$audit_dir/ssl/certbot-certificates.txt" ] && ! grep -q "not installed" "$audit_dir/ssl/certbot-certificates.txt"; then
    echo "**Let's Encrypt Certificates:**" >> "$report"
    echo "" >> "$report"
    echo "\`\`\`" >> "$report"
    cat "$audit_dir/ssl/certbot-certificates.txt" >> "$report"
    echo "\`\`\`" >> "$report"
    echo "" >> "$report"
  else
    echo "No Let's Encrypt certificates found." >> "$report"
    echo "" >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Database Services

EOF

  if [ -s "$audit_dir/databases/database-containers.txt" ] && ! grep -q "No database containers" "$audit_dir/databases/database-containers.txt"; then
    echo "**Database Containers:**" >> "$report"
    echo "" >> "$report"
    echo "\`\`\`" >> "$report"
    cat "$audit_dir/databases/database-containers.txt" >> "$report"
    echo "\`\`\`" >> "$report"
    echo "" >> "$report"
  fi

  if [ -s "$audit_dir/databases/database-ports.txt" ] && ! grep -q "No database ports" "$audit_dir/databases/database-ports.txt"; then
    echo "**Database Ports Listening:**" >> "$report"
    echo "" >> "$report"
    echo "\`\`\`" >> "$report"
    cat "$audit_dir/databases/database-ports.txt" >> "$report"
    echo "\`\`\`" >> "$report"
    echo "" >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Keys & Secrets Discovery

EOF

  if [ -f "$audit_dir/keys/all-env-keys.txt" ]; then
    local key_count
    key_count=$(wc -l < "$audit_dir/keys/all-env-keys.txt" 2>/dev/null || echo "0")
    echo "**Discovered $key_count unique environment variable keys**" >> "$report"
    echo "" >> "$report"
    echo "- Database keys: \`keys/database-keys.txt\`" >> "$report"
    echo "- API keys: \`keys/api-keys.txt\`" >> "$report"
    echo "- Auth keys: \`keys/auth-keys.txt\`" >> "$report"
    echo "- Service keys: \`keys/service-keys.txt\`" >> "$report"
    echo "" >> "$report"
    echo "⚠️ **Security Note:** Only key names were captured, not values." >> "$report"
    echo "" >> "$report"
    echo "See \`keys/KEYS_MIGRATION.md\` for migration guide." >> "$report"
  else
    echo "No environment variables discovered." >> "$report"
  fi

  cat >> "$report" <<EOF

---

## Detailed Container Inspections

See \`containers/*.json\` for full container configurations.

---

## Migration Recommendations

### 1. Nginx Configuration

EOF

  if [ -s "$audit_dir/nginx/nginx-containers.txt" ] || [ -f "$audit_dir/nginx/system-nginx.conf" ]; then
    cat >> "$report" <<EOF
- Copy nginx configs to \`stacks/<stack>/nginx/\`
- Review SSL certificate setup
- Update domain configurations for strut
- Consider using \`strut <stack> domain\` command for SSL automation

EOF
  else
    echo "- No nginx configuration to migrate" >> "$report"
    echo "" >> "$report"
  fi

  cat >> "$report" <<EOF

### 2. Systemd Services

EOF

  if [ -s "$audit_dir/systemd/custom-services.txt" ]; then
    cat >> "$report" <<EOF
- Review custom systemd services in \`systemd/\` directory
- Decide if services should be containerized or remain as system services
- Update service dependencies if migrating to Docker

EOF
  else
    echo "- No custom systemd services to migrate" >> "$report"
    echo "" >> "$report"
  fi

  cat >> "$report" <<EOF

### 3. Cron Jobs

EOF

  if [ -s "$audit_dir/cron/user-crontab.txt" ] || [ -s "$audit_dir/cron/cron.d-contents.txt" ]; then
    cat >> "$report" <<EOF
- Migrate cron jobs to strut backup schedules
- Use \`strut <stack> backup\` commands
- Set up automated backups via cron on VPS

EOF
  else
    echo "- No cron jobs to migrate" >> "$report"
    echo "" >> "$report"
  fi

  cat >> "$report" <<EOF

### 4. Keys & Secrets

- Review \`keys/KEYS_MIGRATION.md\` for detailed migration steps
- Extract secret values from original containers
- Add to stack \`.env.template\` files
- Consider using strut keys management system

### 5. Firewall Rules

- Review current firewall configuration in \`firewall/\`
- Ensure required ports are open for strut services
- Update UFW rules if needed

---

## Next Steps

1. Review this report to understand current setup
2. Check \`STACK_SUGGESTIONS.md\` for recommended stack structure
3. Review \`keys/KEYS_MIGRATION.md\` for secrets migration
4. Use \`strut audit:generate\` to create stack definitions
5. Test deployments in parallel before cutover

EOF

  ok "Report generated: $report"
}

# audit_suggest_stacks <audit_dir>
# Analyzes containers and suggests stack groupings based on compose project labels
audit_suggest_stacks() {
  local audit_dir="$1"
  local suggestions="$audit_dir/STACK_SUGGESTIONS.md"

  log "Analyzing containers for stack suggestions..."

  # Build a mapping file: compose_project -> container lines
  # We use the com.docker.compose.project label from each container
  local project_map="$audit_dir/.stack-project-map.txt"
  : > "$project_map"

  if [ -s "$audit_dir/containers.jsonl" ]; then
    while IFS= read -r line; do
      local name labels project service image ports
      name=$(echo "$line" | jq -r '.Names // ""' 2>/dev/null)
      labels=$(echo "$line" | jq -r '.Labels // ""' 2>/dev/null)
      image=$(echo "$line" | jq -r '.Image // ""' 2>/dev/null)
      ports=$(echo "$line" | jq -r '.Ports // ""' 2>/dev/null)
      local cid
      cid=$(echo "$line" | jq -r '.ID // ""' 2>/dev/null)

      [ -z "$name" ] && continue

      # Extract compose project from labels
      project=""
      if echo "$labels" | grep -q "com.docker.compose.project="; then
        project=$(echo "$labels" | tr ',' '\n' | grep "com.docker.compose.project=" | head -1 | cut -d'=' -f2)
      fi

      # Extract compose service name from labels
      service=""
      if echo "$labels" | grep -q "com.docker.compose.service="; then
        service=$(echo "$labels" | tr ',' '\n' | grep "com.docker.compose.service=" | head -1 | cut -d'=' -f2)
      fi

      # Fall back to container name if no project label
      if [ -z "$project" ]; then
        project=$(echo "$name" | cut -d'-' -f1 | cut -d'_' -f1)
      fi
      if [ -z "$service" ]; then
        service="$name"
      fi

      # Write to map: project|service|name|image|ports|cid
      echo "${project}|${service}|${name}|${image}|${ports}|${cid}" >> "$project_map"
    done < "$audit_dir/containers.jsonl"
  fi

  # Get unique projects
  local projects=()
  while IFS= read -r proj; do
    [ -z "$proj" ] && continue
    projects+=("$proj")
  done < <(cut -d'|' -f1 "$project_map" | sort -u)

  # Also save as machine-readable JSON for Phase 4 to consume
  local suggestions_json="$audit_dir/STACK_SUGGESTIONS.json"
  echo "[" > "$suggestions_json"
  local first_stack=true

  cat > "$suggestions" <<EOF
# Stack Suggestions

Based on the audit, here are suggested stack groupings.
Containers are grouped by their **docker-compose project** (from container labels).

---

EOF

  local stack_idx=0
  for project in "${projects[@]}"; do
    stack_idx=$((stack_idx + 1))

    # Count containers in this project
    local container_count
    container_count=$(grep "^${project}|" "$project_map" | wc -l | tr -d ' ')

    cat >> "$suggestions" <<EOF
## $stack_idx. Project: \`$project\` ($container_count containers)

| # | Service | Container | Image | Ports |
|---|---------|-----------|-------|-------|
EOF

    # JSON entry
    if $first_stack; then
      first_stack=false
    else
      echo "," >> "$suggestions_json"
    fi
    echo "  {" >> "$suggestions_json"
    echo "    \"project\": \"$project\"," >> "$suggestions_json"
    echo "    \"containers\": [" >> "$suggestions_json"

    local svc_idx=0
    local first_container=true
    while IFS='|' read -r _proj svc cname cimage cports ccid; do
      svc_idx=$((svc_idx + 1))
      echo "| $svc_idx | $svc | $cname | \`$cimage\` | \`$cports\` |" >> "$suggestions"

      if $first_container; then
        first_container=false
      else
        echo "," >> "$suggestions_json"
      fi
      echo "      {\"service\": \"$svc\", \"name\": \"$cname\", \"image\": \"$cimage\", \"ports\": \"$cports\", \"id\": \"$ccid\"}" >> "$suggestions_json"
    done < <(grep "^${project}|" "$project_map")

    echo "" >> "$suggestions_json"
    echo "    ]" >> "$suggestions_json"
    echo "  }" >> "$suggestions_json"

    # Show env keys for this project's containers
    local project_env_keys=""
    while IFS='|' read -r _proj _svc _cname _cimage _cports ccid; do
      if [ -f "$audit_dir/secrets/container-${ccid}-env-keys.txt" ]; then
        project_env_keys="$project_env_keys$(cat "$audit_dir/secrets/container-${ccid}-env-keys.txt")"$'\n'
      fi
    done < <(grep "^${project}|" "$project_map")

    local unique_key_count=0
    if [ -n "$project_env_keys" ]; then
      unique_key_count=$(echo "$project_env_keys" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
    fi

    cat >> "$suggestions" <<EOF

**Environment keys:** $unique_key_count unique keys across containers

---

EOF
  done

  echo "]" >> "$suggestions_json"

  cat >> "$suggestions" <<EOF

## How to Use

During Phase 4 (Generate), you'll be shown this list and can:
1. Select which projects to generate as strut stacks
2. Rename them (e.g., \`crm-mcp\` → \`twenty-fastmcp\`)
3. The generator will use actual audit data (images, ports, volumes, env keys)

EOF

  # Clean up temp file
  rm -f "$project_map"

  ok "Stack suggestions generated: $suggestions"
}

# audit_generate_stack <stack_name> <audit_dir> [compose_project]
# Generates a docker-compose.yml from audit data
# If compose_project is provided, uses containers from that project
# Otherwise falls back to matching by stack_name
audit_generate_stack() {
  local stack_name="$1"
  local audit_dir="$2"
  local compose_project="${3:-}"

  [ -n "$stack_name" ] || fail "Usage: audit_generate_stack <stack_name> <audit_dir> [compose_project]"
  [ -d "$audit_dir" ] || fail "Audit directory not found: $audit_dir"

  log "Generating stack definition for: $stack_name"
  if [ -n "$compose_project" ]; then
    log "Using containers from compose project: $compose_project"
  fi

  # Check if stack already exists
  local stack_dir="$CLI_ROOT/stacks/$stack_name"
  if [ -d "$stack_dir" ]; then
    warn "Stack already exists: $stack_name"
    if ! confirm "Overwrite?"; then
      fail "Cancelled by user"
    fi
    # Keep nginx and other custom configs, just regenerate compose + env
  else
    # Create stack directory structure
    log "Creating stack directory: $stack_name"
    mkdir -p "$stack_dir"
    mkdir -p "$stack_dir/nginx/conf.d"
    mkdir -p "$stack_dir/sql/init"
    touch "$stack_dir/sql/init/.gitkeep"
  fi

  local compose_file="$stack_dir/docker-compose.yml"
  local env_template="$stack_dir/.env.template"

  # ── Find matching containers ──────────────────────────────────────────────
  # Build list of containers for this stack
  local match_file="$audit_dir/.gen-match-${stack_name}.txt"
  : > "$match_file"

  if [ -s "$audit_dir/containers.jsonl" ]; then
    while IFS= read -r line; do
      local name labels project
      name=$(echo "$line" | jq -r '.Names // ""' 2>/dev/null)
      labels=$(echo "$line" | jq -r '.Labels // ""' 2>/dev/null)

      # Extract compose project from labels
      project=""
      if echo "$labels" | grep -q "com.docker.compose.project="; then
        project=$(echo "$labels" | tr ',' '\n' | grep "com.docker.compose.project=" | head -1 | cut -d'=' -f2)
      fi

      # Match by compose project if provided, otherwise by stack name
      local matched=false
      if [ -n "$compose_project" ]; then
        [ "$project" = "$compose_project" ] && matched=true
      else
        # Fuzzy match: check project name or container name
        if [ "$project" = "$stack_name" ] || echo "$name" | grep -qi "$stack_name"; then
          matched=true
        fi
      fi

      if $matched; then
        echo "$line" >> "$match_file"
      fi
    done < "$audit_dir/containers.jsonl"
  fi

  local match_count
  match_count=$(wc -l < "$match_file" | tr -d ' ')

  if [ "$match_count" -eq 0 ]; then
    warn "No containers found for stack: $stack_name (project: ${compose_project:-any})"
    warn "The docker-compose.yml will be empty. You'll need to edit it manually."
    rm -f "$match_file"
    return 0
  fi

  log "Found $match_count containers for stack: $stack_name"

  # ── Collect all env keys for this stack ───────────────────────────────────
  local stack_env_keys_file="$audit_dir/.gen-env-keys-${stack_name}.txt"
  : > "$stack_env_keys_file"

  # ── Collect networks used by this stack ───────────────────────────────────
  local stack_networks_file="$audit_dir/.gen-networks-${stack_name}.txt"
  : > "$stack_networks_file"

  # ── Collect volumes used by this stack ────────────────────────────────────
  local stack_volumes_file="$audit_dir/.gen-volumes-${stack_name}.txt"
  : > "$stack_volumes_file"

  # ── Generate docker-compose.yml ───────────────────────────────────────────
  cat > "$compose_file" <<EOF
# Generated from VPS audit: $(basename "$audit_dir")
# Date: $(date)
# Stack: $stack_name
# Source compose project: ${compose_project:-auto-detected}

services:
EOF

  while IFS= read -r line; do
    local name labels cid image ports service_name
    name=$(echo "$line" | jq -r '.Names // ""' 2>/dev/null)
    labels=$(echo "$line" | jq -r '.Labels // ""' 2>/dev/null)
    image=$(echo "$line" | jq -r '.Image // ""' 2>/dev/null)
    ports=$(echo "$line" | jq -r '.Ports // ""' 2>/dev/null)
    cid=$(echo "$line" | jq -r '.ID // ""' 2>/dev/null)

    # Get the compose service name from labels (e.g., "server", "db", "worker")
    service_name=""
    if echo "$labels" | grep -q "com.docker.compose.service="; then
      service_name=$(echo "$labels" | tr ',' '\n' | grep "com.docker.compose.service=" | head -1 | cut -d'=' -f2)
    fi
    [ -z "$service_name" ] && service_name=$(echo "$name" | sed 's/^[^a-zA-Z]*//' | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')

    log "  Adding service: $service_name (from container: $name)"

    # ── Read container inspect for detailed config ──────────────────────
    local inspect_file="$audit_dir/containers/$cid.json"
    local binds="" network_mode="" restart_policy="" healthcheck_test="" healthcheck_interval=""
    local healthcheck_timeout="" healthcheck_retries="" healthcheck_start=""
    local container_env_keys="" depends_on=""

    if [ -f "$inspect_file" ]; then
      # Extract bind mounts
      binds=$(jq -r '.[0].HostConfig.Binds // [] | .[]' "$inspect_file" 2>/dev/null || echo "")

      # Extract network mode
      network_mode=$(jq -r '.[0].HostConfig.NetworkMode // ""' "$inspect_file" 2>/dev/null || echo "")

      # Extract restart policy
      restart_policy=$(jq -r '.[0].HostConfig.RestartPolicy.Name // "unless-stopped"' "$inspect_file" 2>/dev/null || echo "unless-stopped")
      [ "$restart_policy" = "no" ] || [ -z "$restart_policy" ] && restart_policy="unless-stopped"

      # Extract healthcheck
      healthcheck_test=$(jq -r '.[0].Config.Healthcheck.Test // [] | if length > 0 then . else empty end | @json' "$inspect_file" 2>/dev/null || echo "")
      healthcheck_interval=$(jq -r '.[0].Config.Healthcheck.Interval // 0' "$inspect_file" 2>/dev/null || echo "0")
      healthcheck_timeout=$(jq -r '.[0].Config.Healthcheck.Timeout // 0' "$inspect_file" 2>/dev/null || echo "0")
      healthcheck_retries=$(jq -r '.[0].Config.Healthcheck.Retries // 0' "$inspect_file" 2>/dev/null || echo "0")
      healthcheck_start=$(jq -r '.[0].Config.Healthcheck.StartPeriod // 0' "$inspect_file" 2>/dev/null || echo "0")

      # Extract depends_on from labels
      depends_on=""
      if echo "$labels" | grep -q "com.docker.compose.depends_on="; then
        depends_on=$(echo "$labels" | tr ',' '\n' | grep "com.docker.compose.depends_on=" | head -1 | cut -d'=' -f2)
      fi
    fi

    # Track network
    if [ -n "$network_mode" ]; then
      echo "$network_mode" >> "$stack_networks_file"
    fi

    # ── Write service definition ────────────────────────────────────────
    cat >> "$compose_file" <<EOF

  $service_name:
    image: $image
    container_name: $name
    restart: $restart_policy
EOF

    # Ports
    if [ -n "$ports" ] && [ "$ports" != "" ]; then
      # Parse port mappings from the docker ps format
      # Format: "127.0.0.1:8100->8100/tcp" or "0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp"
      local parsed_ports=""
      parsed_ports=$(echo "$ports" | tr ',' '\n' | while IFS= read -r port_entry; do
        port_entry=$(echo "$port_entry" | xargs)  # trim
        [ -z "$port_entry" ] && continue
        if echo "$port_entry" | grep -qF -- "->"; then
          # Has host mapping: "127.0.0.1:8100->8100/tcp"
          local host_part container_part
          host_part=$(echo "$port_entry" | cut -d'>' -f1 | sed 's/-$//')
          container_part=$(echo "$port_entry" | cut -d'>' -f2 | sed 's|/.*||')
          # Skip IPv6 duplicates (addresses starting with [)
          [ "${host_part:0:1}" = "[" ] && continue
          echo "      - \"${host_part}:${container_part}\""
        fi
      done)

      if [ -n "$parsed_ports" ]; then
        echo "    ports:" >> "$compose_file"
        echo "$parsed_ports" >> "$compose_file"
      fi
    fi

    # Environment - reference env_file
    echo "    env_file: .env" >> "$compose_file"

    # Collect env keys for this container
    if [ -f "$audit_dir/secrets/container-${cid}-env-keys.txt" ]; then
      cat "$audit_dir/secrets/container-${cid}-env-keys.txt" >> "$stack_env_keys_file" || true

      # Count non-system env keys for this service (simplified to avoid pipefail issues)
      local svc_key_count=0
      if grep -qv -E '^(PATH|LANG|GPG_KEY|GOSU_VERSION|PYTHON_VERSION|PYTHON_SHA256|NODE_VERSION|YARN_VERSION|PG_MAJOR|PG_VERSION|PGDATA|)$' "$audit_dir/secrets/container-${cid}-env-keys.txt" 2>/dev/null; then
        svc_key_count=$(grep -v -E '^(PATH|LANG|GPG_KEY|GOSU_VERSION|PYTHON_VERSION|PYTHON_SHA256|NODE_VERSION|YARN_VERSION|PG_MAJOR|PG_VERSION|PGDATA|)$' "$audit_dir/secrets/container-${cid}-env-keys.txt" 2>/dev/null | wc -l | tr -d ' ')
      fi
      if [ "$svc_key_count" -gt 0 ] 2>/dev/null; then
        echo "    # $svc_key_count environment variables from audit (see .env.template)" >> "$compose_file"
      fi
    fi

    # Volumes
    if [ -n "$binds" ]; then
      echo "    volumes:" >> "$compose_file"
      echo "$binds" | while IFS= read -r bind; do
        [ -z "$bind" ] && continue
        # Convert absolute VPS paths to relative paths
        # e.g., /opt/my-app/config:/app/config:ro → ./config:/app/config:ro
        local host_path container_path mount_opts
        host_path=$(echo "$bind" | cut -d':' -f1)
        container_path=$(echo "$bind" | cut -d':' -f2)
        mount_opts=$(echo "$bind" | cut -d':' -f3 -s)

        # Check if it's a named volume (no / prefix)
        if echo "$host_path" | grep -q "^/"; then
          # Absolute path - convert to relative
          local relative_path
          relative_path=$(basename "$host_path")
          if [ -n "$mount_opts" ]; then
            echo "      - ./$relative_path:$container_path:$mount_opts" >> "$compose_file"
          else
            echo "      - ./$relative_path:$container_path" >> "$compose_file"
          fi
        else
          # Named volume
          echo "$host_path" >> "$stack_volumes_file"
          if [ -n "$mount_opts" ]; then
            echo "      - $host_path:$container_path:$mount_opts" >> "$compose_file"
          else
            echo "      - $host_path:$container_path" >> "$compose_file"
          fi
        fi
      done
    fi

    # Networks
    if [ -n "$network_mode" ] && [ "$network_mode" != "default" ] && [ "$network_mode" != "bridge" ]; then
      echo "    networks:" >> "$compose_file"
      # Network mode might be like "twenty_default" - use it as-is
      echo "      - $network_mode" >> "$compose_file"
    fi

    # Healthcheck
    if [ -n "$healthcheck_test" ] && [ "$healthcheck_test" != "null" ]; then
      echo "    healthcheck:" >> "$compose_file"
      echo "      test: $healthcheck_test" >> "$compose_file"

      # Convert nanoseconds to human-readable
      if [ "$healthcheck_interval" -gt 0 ] 2>/dev/null; then
        local interval_s=$((healthcheck_interval / 1000000000))
        echo "      interval: ${interval_s}s" >> "$compose_file"
      fi
      if [ "$healthcheck_timeout" -gt 0 ] 2>/dev/null; then
        local timeout_s=$((healthcheck_timeout / 1000000000))
        echo "      timeout: ${timeout_s}s" >> "$compose_file"
      fi
      if [ "$healthcheck_retries" -gt 0 ] 2>/dev/null; then
        echo "      retries: $healthcheck_retries" >> "$compose_file"
      fi
      if [ "$healthcheck_start" -gt 0 ] 2>/dev/null; then
        local start_s=$((healthcheck_start / 1000000000))
        echo "      start_period: ${start_s}s" >> "$compose_file"
      fi
    fi

    # Depends on
    if [ -n "$depends_on" ]; then
      echo "    depends_on:" >> "$compose_file"
      # depends_on format from labels: "server:service_healthy:false,db:service_healthy:false"
      echo "$depends_on" | tr ',' '\n' | while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        local dep_service dep_condition
        dep_service=$(echo "$dep" | cut -d':' -f1)
        dep_condition=$(echo "$dep" | cut -d':' -f2)
        [ -z "$dep_service" ] && continue
        if [ "$dep_condition" = "service_healthy" ]; then
          echo "      $dep_service:" >> "$compose_file"
          echo "        condition: service_healthy" >> "$compose_file"
        else
          echo "      - $dep_service" >> "$compose_file"
        fi
      done
    fi

    # Resource limits (from inspect if available)
    if [ -f "$inspect_file" ]; then
      local cpu_limit mem_limit
      cpu_limit=$(jq -r '.[0].HostConfig.NanoCpus // 0' "$inspect_file" 2>/dev/null || echo "0")
      mem_limit=$(jq -r '.[0].HostConfig.Memory // 0' "$inspect_file" 2>/dev/null || echo "0")

      if [ "$cpu_limit" -gt 0 ] 2>/dev/null || [ "$mem_limit" -gt 0 ] 2>/dev/null; then
        echo "    deploy:" >> "$compose_file"
        echo "      resources:" >> "$compose_file"
        echo "        limits:" >> "$compose_file"
        if [ "$cpu_limit" -gt 0 ] 2>/dev/null; then
          local cpu_val
          cpu_val=$(echo "scale=1; $cpu_limit / 1000000000" | bc 2>/dev/null || echo "1")
          echo "          cpus: '$cpu_val'" >> "$compose_file"
        fi
        if [ "$mem_limit" -gt 0 ] 2>/dev/null; then
          local mem_mb
          mem_mb=$((mem_limit / 1048576))
          echo "          memory: ${mem_mb}M" >> "$compose_file"
        fi
      fi
    fi

  done < "$match_file"

  # ── Volumes section ───────────────────────────────────────────────────────
  local unique_volumes
  unique_volumes=$(sort -u "$stack_volumes_file" 2>/dev/null | grep -v '^$' || echo "")

  if [ -n "$unique_volumes" ]; then
    echo "" >> "$compose_file"
    echo "volumes:" >> "$compose_file"
    echo "$unique_volumes" | while IFS= read -r vol; do
      [ -z "$vol" ] && continue
      echo "  $vol:" >> "$compose_file"
      # Check if this volume exists on VPS (mark as external)
      if [ -s "$audit_dir/volumes.jsonl" ]; then
        if grep -qF "\"Name\":\"$vol\"" "$audit_dir/volumes.jsonl" 2>/dev/null; then
          echo "    external: true" >> "$compose_file"
        fi
      fi
    done
  fi

  # ── Networks section ──────────────────────────────────────────────────────
  local unique_networks
  unique_networks=$(sort -u "$stack_networks_file" 2>/dev/null | grep -v '^$' | grep -v '^default$' | grep -v '^bridge$' || echo "")

  if [ -n "$unique_networks" ]; then
    echo "" >> "$compose_file"
    echo "networks:" >> "$compose_file"
    echo "$unique_networks" | while IFS= read -r net; do
      [ -z "$net" ] && continue
      echo "  $net:" >> "$compose_file"
      # Check if network is external
      if [ -s "$audit_dir/networks.jsonl" ]; then
        if grep -qF "\"Name\":\"$net\"" "$audit_dir/networks.jsonl" 2>/dev/null; then
          echo "    external: true" >> "$compose_file"
        fi
      fi
    done
  fi

  ok "Stack definition generated: $compose_file"

  # ── Generate .env.template with actual keys ───────────────────────────────
  log "Generating environment template from audit data..."

  # System/runtime env vars to exclude from template
  local system_keys="PATH|LANG|GPG_KEY|GOSU_VERSION|PYTHON_VERSION|PYTHON_SHA256|NODE_VERSION|YARN_VERSION|PG_MAJOR|PG_VERSION|PGDATA|HOSTNAME"

  # Get unique non-system keys
  local app_keys
  app_keys=$(grep -v '^$' "$stack_env_keys_file" 2>/dev/null | sort -u | grep -v -E "^($system_keys)$" || echo "")

  cat > "$env_template" <<EOF
# Environment variables for $stack_name stack
# Generated from VPS audit: $(basename "$audit_dir")
# Source compose project: ${compose_project:-auto-detected}
# Date: $(date)
#
# These keys were discovered from running containers on the VPS.
# Fill in the actual values before deploying.
# To pull values from VPS: strut $stack_name keys pull --from vps

EOF

  if [ -n "$app_keys" ]; then
    # Group keys by category
    local db_keys api_keys auth_keys service_keys other_keys
    db_keys=$(echo "$app_keys" | grep -iE '(DATABASE|DB|POSTGRES|MYSQL|MONGO|REDIS|NEO4J|PG_DATABASE)' || echo "")
    api_keys=$(echo "$app_keys" | grep -iE '(API_KEY|APIKEY|API_SECRET|API_TOKEN|API_URL|MCP_BASE_URL|SERVER_URL|REACT_APP_)' || echo "")
    auth_keys=$(echo "$app_keys" | grep -iE '(SECRET|PASSWORD|PASS|AUTH|JWT|SESSION|TOKEN|OAUTH|CLIENT_ID|CLIENT_SECRET|GOOGLE_CLIENT)' | grep -v -iE '(API_TOKEN|API_KEY)' || echo "")
    service_keys=$(echo "$app_keys" | grep -iE '(SMTP|EMAIL|TWILIO|AWS|GCP|AZURE|GITHUB|GITLAB|STORAGE|S3)' || echo "")

    # "Other" = everything not in the above categories
    local categorized_keys=""
    [ -n "$db_keys" ] && categorized_keys="$categorized_keys"$'\n'"$db_keys"
    [ -n "$api_keys" ] && categorized_keys="$categorized_keys"$'\n'"$api_keys"
    [ -n "$auth_keys" ] && categorized_keys="$categorized_keys"$'\n'"$auth_keys"
    [ -n "$service_keys" ] && categorized_keys="$categorized_keys"$'\n'"$service_keys"

    other_keys=$(echo "$app_keys" | while IFS= read -r key; do
      [ -z "$key" ] && continue
      if ! echo "$categorized_keys" | grep -q "^${key}$"; then
        echo "$key"
      fi
    done)

    if [ -n "$db_keys" ]; then
      echo "# ── Database ────────────────────────────────────────────" >> "$env_template"
      echo "$db_keys" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        echo "${key}=" >> "$env_template"
      done
      echo "" >> "$env_template"
    fi

    if [ -n "$auth_keys" ]; then
      echo "# ── Authentication & Secrets ─────────────────────────────" >> "$env_template"
      echo "$auth_keys" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        echo "${key}=" >> "$env_template"
      done
      echo "" >> "$env_template"
    fi

    if [ -n "$api_keys" ]; then
      echo "# ── API & Service URLs ──────────────────────────────────" >> "$env_template"
      echo "$api_keys" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        echo "${key}=" >> "$env_template"
      done
      echo "" >> "$env_template"
    fi

    if [ -n "$service_keys" ]; then
      echo "# ── External Services ───────────────────────────────────" >> "$env_template"
      echo "$service_keys" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        echo "${key}=" >> "$env_template"
      done
      echo "" >> "$env_template"
    fi

    if [ -n "$other_keys" ]; then
      echo "# ── Application Config ──────────────────────────────────" >> "$env_template"
      echo "$other_keys" | while IFS= read -r key; do
        [ -z "$key" ] && continue
        echo "${key}=" >> "$env_template"
      done
      echo "" >> "$env_template"
    fi
  else
    echo "# No environment variables discovered from audit." >> "$env_template"
    echo "# Add your variables below:" >> "$env_template"
    echo "" >> "$env_template"
  fi

  ok "Environment template generated: $env_template"

  # Clean up temp files
  rm -f "$match_file" "$stack_env_keys_file" "$stack_networks_file" "$stack_volumes_file"

  echo ""
  echo -e "${BLUE}Next steps:${NC}"
  echo "  1. Review: $compose_file"
  echo "  2. Create env: cp $env_template .$stack_name-prod.env"
  echo "  3. Fill secrets in .$stack_name-prod.env"
  echo "  4. Deploy: strut $stack_name deploy --env ${stack_name}-prod"
  echo ""
}

# audit_list <audit_dir>
# Lists all audits
audit_list() {
  local audits_dir="$CLI_ROOT/audits"

  if [ ! -d "$audits_dir" ] || [ -z "$(ls -A "$audits_dir" 2>/dev/null)" ]; then
    warn "No audits found in $audits_dir"
    return 0
  fi

  echo ""
  echo -e "${BLUE}Available audits:${NC}"
  echo ""

  for audit_dir in "$audits_dir"/*; do
    [ -d "$audit_dir" ] || continue
    local audit_name
    audit_name=$(basename "$audit_dir")
    local report="$audit_dir/REPORT.md"

    if [ -f "$report" ]; then
      local vps_host
      vps_host=$(grep "^\*\*VPS:\*\*" "$report" | sed 's/.*VPS:\*\* //' || echo "Unknown")
      echo -e "  ${GREEN}✓${NC} $audit_name"
      echo -e "    VPS: $vps_host"
      echo -e "    Report: $report"
    else
      echo -e "  ${YELLOW}?${NC} $audit_name (incomplete)"
    fi
    echo ""
  done
}
