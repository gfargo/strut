#!/usr/bin/env bats
# ==================================================
# tests/test_audit.bats — Tests for lib/audit.sh pure functions
# ==================================================
# Run:  bats tests/test_audit.bats
# Covers: audit_suggest_stacks, audit_generate_report, audit_list,
#         _audit_keys, _audit_keys_migration_template
#
# These tests exercise the report-generation and analysis functions
# that don't require SSH connectivity.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  # Override output helpers
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "BANNER: $*"; }
  confirm() { return 1; }  # Default: decline confirmations
  export -f fail ok warn log error print_banner confirm

  # Color vars
  export RED="" GREEN="" YELLOW="" BLUE="" NC=""

  source "$CLI_ROOT/lib/audit.sh"
}

teardown() { common_teardown; }

# ── _audit_keys_migration_template ───────────────────────────────────────────

@test "_audit_keys_migration_template: generates KEYS_MIGRATION.md" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/keys"

  _audit_keys_migration_template "$audit_dir"

  [ -f "$audit_dir/keys/KEYS_MIGRATION.md" ]
  local content
  content=$(cat "$audit_dir/keys/KEYS_MIGRATION.md")
  [[ "$content" == *"Keys Migration Guide"* ]]
  [[ "$content" == *"Discovered Keys"* ]]
  [[ "$content" == *"Migration Steps"* ]]
  [[ "$content" == *"Security Notes"* ]]
}

# ── _audit_keys ───────────────────────────────────────────────────────────────

@test "_audit_keys: creates key category files" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  # Create fake container env key files
  cat > "$audit_dir/secrets/container-abc123-env-keys.txt" <<'EOF'
DATABASE_URL
POSTGRES_PASSWORD
API_KEY
JWT_SECRET
SMTP_HOST
APP_PORT
EOF

  cat > "$audit_dir/secrets/container-def456-env-keys.txt" <<'EOF'
REDIS_URL
AWS_ACCESS_KEY_ID
SESSION_SECRET
EOF

  _audit_keys "$audit_dir"

  # Should create the keys directory and files
  [ -d "$audit_dir/keys" ]
  [ -f "$audit_dir/keys/all-env-keys.txt" ]
  [ -f "$audit_dir/keys/database-keys.txt" ]
  [ -f "$audit_dir/keys/api-keys.txt" ]
  [ -f "$audit_dir/keys/auth-keys.txt" ]
  [ -f "$audit_dir/keys/service-keys.txt" ]
  [ -f "$audit_dir/keys/KEYS_MIGRATION.md" ]
}

@test "_audit_keys: all-env-keys.txt contains unique sorted keys" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  cat > "$audit_dir/secrets/container-abc-env-keys.txt" <<'EOF'
APP_PORT
DATABASE_URL
APP_PORT
EOF

  _audit_keys "$audit_dir"

  # Should be deduplicated
  local count
  count=$(wc -l < "$audit_dir/keys/all-env-keys.txt" | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "_audit_keys: categorizes database keys correctly" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  cat > "$audit_dir/secrets/container-abc-env-keys.txt" <<'EOF'
DATABASE_URL
POSTGRES_PASSWORD
DB_HOST
REDIS_URL
APP_NAME
EOF

  _audit_keys "$audit_dir"

  local db_keys
  db_keys=$(cat "$audit_dir/keys/database-keys.txt")
  [[ "$db_keys" == *"DATABASE_URL"* ]]
  [[ "$db_keys" == *"POSTGRES_PASSWORD"* ]]
  [[ "$db_keys" == *"DB_HOST"* ]]
  [[ "$db_keys" == *"REDIS_URL"* ]]
  # APP_NAME should NOT be in database keys
  [[ "$db_keys" != *"APP_NAME"* ]]
}

@test "_audit_keys: categorizes auth keys correctly" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  cat > "$audit_dir/secrets/container-abc-env-keys.txt" <<'EOF'
JWT_SECRET
SESSION_KEY
PASSWORD_SALT
AUTH_TOKEN
APP_PORT
EOF

  _audit_keys "$audit_dir"

  local auth_keys
  auth_keys=$(cat "$audit_dir/keys/auth-keys.txt")
  [[ "$auth_keys" == *"JWT_SECRET"* ]]
  [[ "$auth_keys" == *"SESSION_KEY"* ]]
  [[ "$auth_keys" == *"PASSWORD_SALT"* ]]
  [[ "$auth_keys" == *"AUTH_TOKEN"* ]]
  [[ "$auth_keys" != *"APP_PORT"* ]]
}

@test "_audit_keys: handles empty secrets directory" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  # No container env key files
  _audit_keys "$audit_dir"

  [ -d "$audit_dir/keys" ]
  [ -f "$audit_dir/keys/KEYS_MIGRATION.md" ]
}

# ── audit_generate_report ─────────────────────────────────────────────────────

@test "audit_generate_report: creates REPORT.md with correct structure" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/nginx" "$audit_dir/caddy" "$audit_dir/systemd" \
           "$audit_dir/cron" "$audit_dir/firewall" "$audit_dir/ssl" \
           "$audit_dir/databases" "$audit_dir/keys"

  # Create minimal fixture data
  echo '{"Names":"web-1","Image":"nginx:latest","Ports":"0.0.0.0:80->80/tcp","Status":"Up 2 days"}' > "$audit_dir/containers.jsonl"
  echo '{"Names":"web-1","Image":"nginx:latest","Ports":"0.0.0.0:80->80/tcp","Status":"Up 2 days"}' > "$audit_dir/containers-all.jsonl"
  echo '{"Name":"data-vol","Driver":"local"}' > "$audit_dir/volumes.jsonl"
  echo '{"Name":"bridge","Driver":"bridge"}' > "$audit_dir/networks.jsonl"
  echo '{"Repository":"nginx","Tag":"latest"}' > "$audit_dir/images.jsonl"
  echo ":80 LISTEN" > "$audit_dir/ports.txt"
  echo "/dev/sda1 50G 20G 30G 40% /" > "$audit_dir/disk-usage.txt"
  echo "No docker disk usage" > "$audit_dir/docker-disk-usage.txt"
  echo "/opt/app/docker-compose.yml" > "$audit_dir/compose-files.txt"
  echo "UFW not installed" > "$audit_dir/firewall/ufw-status.txt"
  echo "Certbot not installed" > "$audit_dir/ssl/certbot-certificates.txt"
  echo "No database containers found" > "$audit_dir/databases/database-containers.txt"
  echo "No database ports detected" > "$audit_dir/databases/database-ports.txt"
  echo "No user crontab" > "$audit_dir/cron/user-crontab.txt"
  touch "$audit_dir/nginx/nginx-containers.txt"
  touch "$audit_dir/caddy/caddy-containers.txt"
  touch "$audit_dir/systemd/custom-services.txt"
  touch "$audit_dir/cron/cron.d-contents.txt"

  audit_generate_report "$audit_dir" "test-vps.example.com"

  [ -f "$audit_dir/REPORT.md" ]
  local report
  report=$(cat "$audit_dir/REPORT.md")
  [[ "$report" == *"VPS Audit Report"* ]]
  [[ "$report" == *"test-vps.example.com"* ]]
  [[ "$report" == *"Running Containers"* ]]
  [[ "$report" == *"Volumes"* ]]
  [[ "$report" == *"Port Usage"* ]]
  [[ "$report" == *"Disk Usage"* ]]
}

@test "audit_generate_report: includes container table" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/nginx" "$audit_dir/caddy" "$audit_dir/systemd" \
           "$audit_dir/cron" "$audit_dir/firewall" "$audit_dir/ssl" \
           "$audit_dir/databases" "$audit_dir/keys"

  echo '{"Names":"my-app","Image":"node:18","Ports":"0.0.0.0:3000->3000/tcp","Status":"Up 5 hours"}' > "$audit_dir/containers.jsonl"
  echo '{"Names":"my-app","Image":"node:18","Ports":"0.0.0.0:3000->3000/tcp","Status":"Up 5 hours"}' > "$audit_dir/containers-all.jsonl"
  : > "$audit_dir/volumes.jsonl"
  : > "$audit_dir/networks.jsonl"
  : > "$audit_dir/images.jsonl"
  : > "$audit_dir/ports.txt"
  echo "/ 50G" > "$audit_dir/disk-usage.txt"
  : > "$audit_dir/docker-disk-usage.txt"
  : > "$audit_dir/compose-files.txt"
  echo "inactive" > "$audit_dir/firewall/ufw-status.txt"
  echo "not installed" > "$audit_dir/ssl/certbot-certificates.txt"
  echo "No database containers" > "$audit_dir/databases/database-containers.txt"
  echo "No database ports" > "$audit_dir/databases/database-ports.txt"
  echo "No user crontab" > "$audit_dir/cron/user-crontab.txt"
  touch "$audit_dir/nginx/nginx-containers.txt"
  touch "$audit_dir/caddy/caddy-containers.txt"
  touch "$audit_dir/systemd/custom-services.txt"
  touch "$audit_dir/cron/cron.d-contents.txt"

  audit_generate_report "$audit_dir" "test.local"

  local report
  report=$(cat "$audit_dir/REPORT.md")
  [[ "$report" == *"my-app"* ]]
  [[ "$report" == *"node:18"* ]]
}

# ── audit_suggest_stacks ──────────────────────────────────────────────────────

@test "audit_suggest_stacks: generates STACK_SUGGESTIONS.md" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  # Create containers with compose project labels
  cat > "$audit_dir/containers.jsonl" <<'EOF'
{"Names":"myapp-web-1","Image":"nginx:latest","Ports":"80:80","Labels":"com.docker.compose.project=myapp,com.docker.compose.service=web","ID":"abc123"}
{"Names":"myapp-api-1","Image":"node:18","Ports":"3000:3000","Labels":"com.docker.compose.project=myapp,com.docker.compose.service=api","ID":"def456"}
EOF

  audit_suggest_stacks "$audit_dir"

  [ -f "$audit_dir/STACK_SUGGESTIONS.md" ]
  [ -f "$audit_dir/STACK_SUGGESTIONS.json" ]

  local suggestions
  suggestions=$(cat "$audit_dir/STACK_SUGGESTIONS.md")
  [[ "$suggestions" == *"Stack Suggestions"* ]]
  [[ "$suggestions" == *"myapp"* ]]
  [[ "$suggestions" == *"2 containers"* ]]
  [[ "$suggestions" == *"web"* ]]
  [[ "$suggestions" == *"api"* ]]
}

@test "audit_suggest_stacks: groups containers by compose project" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  cat > "$audit_dir/containers.jsonl" <<'EOF'
{"Names":"app-web","Image":"nginx","Ports":"80:80","Labels":"com.docker.compose.project=app,com.docker.compose.service=web","ID":"a1"}
{"Names":"app-db","Image":"postgres","Ports":"5432:5432","Labels":"com.docker.compose.project=app,com.docker.compose.service=db","ID":"a2"}
{"Names":"monitor-grafana","Image":"grafana/grafana","Ports":"3000:3000","Labels":"com.docker.compose.project=monitor,com.docker.compose.service=grafana","ID":"b1"}
EOF

  audit_suggest_stacks "$audit_dir"

  local suggestions
  suggestions=$(cat "$audit_dir/STACK_SUGGESTIONS.md")
  # Should have two project groups
  [[ "$suggestions" == *"app"* ]]
  [[ "$suggestions" == *"monitor"* ]]
  [[ "$suggestions" == *"2 containers"* ]]  # app has 2
  [[ "$suggestions" == *"1 containers"* ]]  # monitor has 1
}

@test "audit_suggest_stacks: handles containers without compose labels" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  cat > "$audit_dir/containers.jsonl" <<'EOF'
{"Names":"standalone-nginx","Image":"nginx","Ports":"80:80","Labels":"","ID":"x1"}
EOF

  audit_suggest_stacks "$audit_dir"

  [ -f "$audit_dir/STACK_SUGGESTIONS.md" ]
  local suggestions
  suggestions=$(cat "$audit_dir/STACK_SUGGESTIONS.md")
  # Should fall back to container name prefix
  [[ "$suggestions" == *"standalone"* ]]
}

@test "audit_suggest_stacks: generates valid JSON" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"

  cat > "$audit_dir/containers.jsonl" <<'EOF'
{"Names":"web","Image":"nginx","Ports":"80:80","Labels":"com.docker.compose.project=demo,com.docker.compose.service=web","ID":"w1"}
EOF

  audit_suggest_stacks "$audit_dir"

  # Validate JSON structure
  run jq '.' "$audit_dir/STACK_SUGGESTIONS.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo"* ]]
}

@test "audit_suggest_stacks: handles empty containers file" {
  local audit_dir="$TEST_TMP/audit"
  mkdir -p "$audit_dir/secrets"
  : > "$audit_dir/containers.jsonl"

  audit_suggest_stacks "$audit_dir"

  [ -f "$audit_dir/STACK_SUGGESTIONS.md" ]
  [ -f "$audit_dir/STACK_SUGGESTIONS.json" ]
}

# ── audit_list ────────────────────────────────────────────────────────────────

@test "audit_list: warns when no audits directory exists" {
  export CLI_ROOT="$TEST_TMP"

  run audit_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No audits found"* ]]
}

@test "audit_list: warns when audits directory is empty" {
  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/audits"

  run audit_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No audits found"* ]]
}

@test "audit_list: lists audits with reports" {
  export CLI_ROOT="$TEST_TMP"
  local audit_dir="$TEST_TMP/audits/20240101-120000-myhost"
  mkdir -p "$audit_dir"
  cat > "$audit_dir/REPORT.md" <<'EOF'
# VPS Audit Report

**VPS:** myhost.example.com
**Date:** 2024-01-01
EOF

  run audit_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"20240101-120000-myhost"* ]]
  [[ "$output" == *"myhost.example.com"* ]]
}

@test "audit_list: marks incomplete audits" {
  export CLI_ROOT="$TEST_TMP"
  local audit_dir="$TEST_TMP/audits/20240101-120000-incomplete"
  mkdir -p "$audit_dir"
  # No REPORT.md

  run audit_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"incomplete"* ]]
}
