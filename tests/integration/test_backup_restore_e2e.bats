#!/usr/bin/env bats
# ==================================================
# tests/integration/test_backup_restore_e2e.bats — Backup/restore round trips
# ==================================================
# OSS-399 / strut#253: backup_* / restore_* had zero integration coverage —
# only mocked safety-check coverage exists (tests/test_backup_restore_safety.bats).
# This proves the real round trip against real database engines: write a
# marker row, back it up, destroy the marker, restore, assert the marker
# survived.
#
# Each engine gets its own independent compose project/container brought up
# directly with `docker compose`/`docker run` (not via `strut deploy`, which
# would require services.conf/required_vars scaffolding these tests don't
# need) so a failure in one engine's block can't cascade into the others.
#
# Lives in tests/integration/ (Docker required) — see test_e2e.bats for the
# rationale. Run locally with: bats tests/integration/

_skip_without_docker() {
  command -v docker >/dev/null 2>&1 || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"
}

# _wait_ready <label> <max_attempts> <interval> <check_cmd...>
#
# Polls <check_cmd> until it succeeds twice in a row before trusting
# readiness. A single success isn't proof: Postgres and MySQL both run a
# temporary bootstrap server during initialization (init scripts, root
# password/grant setup) that can answer a liveness probe successfully
# moments before shutting down to hand off to the real server — a
# false-positive "ready" window that a bare pg_isready/mysqladmin-ping poll
# will happily report as success. Requiring two consecutive successes
# closes that window, mirroring the belt-and-suspenders pattern the
# blue-green health gate uses against the analogous crash-loop race
# (lib/deploy_blue_green.sh's _bg_wait_healthy + _bg_any_container_restarted).
_wait_ready() {
  local label="$1" max_attempts="$2" interval="$3"
  shift 3
  local consecutive_ok=0
  local attempt
  for attempt in $(seq 1 "$max_attempts"); do
    if "$@" >/dev/null 2>&1; then
      consecutive_ok=$((consecutive_ok + 1))
      [ "$consecutive_ok" -ge 2 ] && return 0
    else
      consecutive_ok=0
    fi
    sleep "$interval"
  done
  echo "timed out waiting for $label to be ready" >&2
  return 1
}

setup_file() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export CLI_ROOT
  export STRUT_HOME="$CLI_ROOT"
  export POSTGRES_USER="postgres"
  export POSTGRES_DB="app_db"

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    return 0
  fi

  export BR_SUFFIX="$$-$(date +%s)"

  # ── Postgres fixture ──────────────────────────────────────────────────────
  export PG_STACK="pgbr-${BR_SUFFIX}"
  export PG_PROJECT="${PG_STACK}-test"
  export PG_STACK_DIR="$CLI_ROOT/stacks/$PG_STACK"
  mkdir -p "$PG_STACK_DIR"
  cat > "$PG_STACK_DIR/docker-compose.yml" <<EOF
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: app_db
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
EOF
  export PG_COMPOSE_CMD="docker compose --project-name $PG_PROJECT -f $PG_STACK_DIR/docker-compose.yml"
  $PG_COMPOSE_CMD up -d >/dev/null 2>&1

  # ── MySQL fixture ─────────────────────────────────────────────────────────
  export MYSQL_STACK="mysqlbr-${BR_SUFFIX}"
  export MYSQL_PROJECT="${MYSQL_STACK}-test"
  export MYSQL_STACK_DIR="$CLI_ROOT/stacks/$MYSQL_STACK"
  export MYSQL_CONTAINER_NAME="${MYSQL_STACK}-mysql"
  mkdir -p "$MYSQL_STACK_DIR"
  cat > "$MYSQL_STACK_DIR/docker-compose.yml" <<EOF
services:
  mysql:
    image: mysql:8
    container_name: ${MYSQL_CONTAINER_NAME}
    environment:
      MYSQL_ROOT_PASSWORD: testpass
      MYSQL_DATABASE: app_db
EOF
  export MYSQL_COMPOSE_CMD="docker compose --project-name $MYSQL_PROJECT -f $MYSQL_STACK_DIR/docker-compose.yml"
  $MYSQL_COMPOSE_CMD up -d >/dev/null 2>&1

  # Give both engines time to accept connections — polled per-test below,
  # this is just so setup_file doesn't return before `up -d` has even
  # created the containers.
  sleep 2
}

teardown_file() {
  [ -z "${BR_SUFFIX:-}" ] && return 0

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    [ -n "${PG_COMPOSE_CMD:-}" ] && $PG_COMPOSE_CMD down --volumes --remove-orphans >/dev/null 2>&1 || true
    [ -n "${MYSQL_COMPOSE_CMD:-}" ] && $MYSQL_COMPOSE_CMD down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi

  rm -rf "${PG_STACK_DIR:-/nonexistent}" "${MYSQL_STACK_DIR:-/nonexistent}"
}

setup() {
  _skip_without_docker
  source "$CLI_ROOT/lib/utils.sh"
  source "$CLI_ROOT/lib/config.sh"
  confirm() { return 0; }
  source "$CLI_ROOT/lib/backup.sh"
}

# ── Postgres round trip ────────────────────────────────────────────────────────

@test "postgres backup/restore: marker row survives a full backup -> destroy -> restore cycle" {
  # Wait for Postgres to accept real queries (not just answer pg_isready —
  # see _wait_ready above).
  run _wait_ready "postgres" 30 2 \
    $PG_COMPOSE_CMD exec -T postgres psql -U postgres -d app_db -c "SELECT 1;"
  [ "$status" -eq 0 ]

  run $PG_COMPOSE_CMD exec -T postgres psql -U postgres -d app_db \
    -c "CREATE TABLE marker (val text); INSERT INTO marker VALUES ('backup-restore-e2e');"
  [ "$status" -eq 0 ]

  run backup_postgres "$PG_STACK" "$PG_COMPOSE_CMD"
  [ "$status" -eq 0 ]

  local dump_file
  dump_file=$(ls -t "$CLI_ROOT/stacks/$PG_STACK/backups"/postgres-*.sql 2>/dev/null | head -1)
  [ -n "$dump_file" ]
  [ -s "$dump_file" ]

  # Destroy the marker data — simulates the disaster restore is meant to fix.
  run $PG_COMPOSE_CMD exec -T postgres psql -U postgres -d app_db -c "DROP TABLE marker;"
  [ "$status" -eq 0 ]

  run restore_postgres "$PG_STACK" "$PG_COMPOSE_CMD" "$dump_file"
  [ "$status" -eq 0 ]

  run $PG_COMPOSE_CMD exec -T postgres psql -U postgres -d app_db -tAc "SELECT val FROM marker;"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-restore-e2e"* ]]
}

# ── MySQL round trip ───────────────────────────────────────────────────────────

@test "mysql backup/restore: marker row survives a full backup -> destroy -> restore cycle" {
  # `mysqladmin ping` answers successfully against MySQL's temporary
  # bootstrap server (used while docker-entrypoint runs init scripts) before
  # the real server — with the configured database and credentials — is up.
  # Confirmed locally: ping can report ready ~1-2s before an authenticated
  # query actually succeeds. Poll with a real query instead (see _wait_ready
  # above).
  run _wait_ready "mysql" 30 3 \
    docker exec "$MYSQL_CONTAINER_NAME" mysql -uroot -ptestpass -e "SELECT 1;"
  [ "$status" -eq 0 ]

  export MYSQL_DATABASE="app_db"
  export MYSQL_ROOT_PASSWORD="testpass"

  run docker exec "$MYSQL_CONTAINER_NAME" \
    mysql -uroot -ptestpass app_db \
    -e "CREATE TABLE marker (val VARCHAR(64)); INSERT INTO marker VALUES ('backup-restore-e2e');"
  [ "$status" -eq 0 ]

  run backup_mysql "$MYSQL_STACK" "$MYSQL_COMPOSE_CMD"
  [ "$status" -eq 0 ]

  local dump_file
  dump_file=$(ls -t "$CLI_ROOT/stacks/$MYSQL_STACK/backups"/mysql-*.sql 2>/dev/null | head -1)
  [ -n "$dump_file" ]
  [ -s "$dump_file" ]

  run docker exec "$MYSQL_CONTAINER_NAME" mysql -uroot -ptestpass app_db -e "DROP TABLE marker;"
  [ "$status" -eq 0 ]

  run restore_mysql "$MYSQL_STACK" "$MYSQL_COMPOSE_CMD" "$dump_file"
  [ "$status" -eq 0 ]

  run docker exec "$MYSQL_CONTAINER_NAME" mysql -uroot -ptestpass app_db -N -e "SELECT val FROM marker;"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-restore-e2e"* ]]
}
