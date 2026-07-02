#!/usr/bin/env bash
# Pre-record setup: called silently during the Hide block of live tapes.
# Writes .prod.env from environment, sets up the probe stack, and does a
# best-effort cleanup so the recording starts from a known state.
set -eu

# Fixture project lives at bin/tapes/ — VHS is running from there.
: "${STRUT_LIVE_HOST:?}"; : "${STRUT_LIVE_USER:?}"; : "${STRUT_LIVE_SSH_KEY:?}"

cat > .prod.env <<EOF
VPS_HOST=$STRUT_LIVE_HOST
VPS_USER=$STRUT_LIVE_USER
VPS_SSH_KEY=$STRUT_LIVE_SSH_KEY
REGISTRY_TYPE=none
EOF
chmod 600 .prod.env

mkdir -p stacks/probe
cat > stacks/probe/docker-compose.yml <<'YAML'
services:
  probe:
    image: alpine
YAML

# Best-effort pre-cleanup of any container the last recording left behind.
strut probe exec 'docker rm -f live-demo-nginx 2>/dev/null || true' --env prod >/dev/null 2>&1 || true
