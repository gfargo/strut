#!/bin/sh
# ==================================================
# docker-entrypoint.sh — Wait for deps, then exec
# ==================================================
# Waits for required services to be ready before starting the application.
# Replaces custom bash loops in each service's Dockerfile.
#
# Configure via environment variables:
#   WAIT_HOSTS  — comma-separated list of "host:port" pairs to wait for
#   WAIT_TIMEOUT — max seconds to wait (default: 60)
#
# Example:
#   WAIT_HOSTS=redis:6379,postgres:5432

set -e

WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
ELAPSED=0

wait_for_host() {
  local host="$1"
  local port="$2"
  local elapsed=0

  echo "[entrypoint] Waiting for $host:$port..."
  while ! nc -z "$host" "$port" 2>/dev/null; do
    if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
      echo "[entrypoint] ERROR: Timed out waiting for $host:$port after ${WAIT_TIMEOUT}s"
      exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "[entrypoint] $host:$port is ready (${elapsed}s)"
}

# Parse WAIT_HOSTS (comma-separated host:port pairs)
if [ -n "${WAIT_HOSTS:-}" ]; then
  for hostport in $(echo "$WAIT_HOSTS" | tr ',' ' '); do
    host="${hostport%%:*}"
    port="${hostport##*:}"
    wait_for_host "$host" "$port"
  done
fi

# Hand off to the main process
exec "$@"
