#!/usr/bin/env bash
# ==================================================
# record-live.sh — Render live-VPS demo tapes with real credentials
# ==================================================
# The live tapes (bin/tapes/live/*.tape) run REAL strut commands against a
# real VPS. This wrapper:
#   1. Loads STRUT_LIVE_HOST / _USER / _SSH_KEY from ~/.strut-live.env (gitignored)
#      or from your current environment.
#   2. Renders one or all live tapes.
#
# Usage:
#   bin/record-live.sh                           # render all live tapes
#   bin/record-live.sh live-preflight.tape       # render one tape by name
#
# Create ~/.strut-live.env once:
#   STRUT_LIVE_HOST=<vps-ip>
#   STRUT_LIVE_USER=root
#   STRUT_LIVE_SSH_KEY=/absolute/path/to/private-key
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRUT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Load credentials (env wins over file) ─────────────────────────────────
if [ -f "$HOME/.strut-live.env" ] && [ -z "${STRUT_LIVE_HOST:-}" ]; then
  # shellcheck disable=SC1091
  set -a; source "$HOME/.strut-live.env"; set +a
fi

: "${STRUT_LIVE_HOST:?set STRUT_LIVE_HOST (VPS IP/host) — see ~/.strut-live.env}"
: "${STRUT_LIVE_USER:?set STRUT_LIVE_USER (usually root)}"
: "${STRUT_LIVE_SSH_KEY:?set STRUT_LIVE_SSH_KEY (path to private key)}"
[ -r "$STRUT_LIVE_SSH_KEY" ] || { echo "SSH key not readable: $STRUT_LIVE_SSH_KEY" >&2; exit 1; }

export STRUT_LIVE_HOST STRUT_LIVE_USER STRUT_LIVE_SSH_KEY

command -v vhs >/dev/null || { echo "vhs not installed (brew install vhs)" >&2; exit 1; }

# ── Sanity check connectivity before spending time on a recording ─────────
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
     -i "$STRUT_LIVE_SSH_KEY" "$STRUT_LIVE_USER@$STRUT_LIVE_HOST" \
     "echo pong" >/dev/null 2>&1; then
  echo "✗ SSH probe failed for $STRUT_LIVE_USER@$STRUT_LIVE_HOST" >&2
  exit 1
fi
echo "✓ VPS reachable at $STRUT_LIVE_USER@$STRUT_LIVE_HOST"

# ── Render tapes ─────────────────────────────────────────────────────────
cd "$SCRIPT_DIR/tapes"

if [ $# -gt 0 ]; then
  targets=("$@")
else
  targets=(live/*.tape)
fi

for tape in "${targets[@]}"; do
  # Allow bare name (live-preflight.tape) or full path (live/live-preflight.tape)
  case "$tape" in
    live/*) : ;;
    *)      tape="live/$tape" ;;
  esac
  [ -f "$tape" ] || { echo "✗ Not found: $tape" >&2; exit 1; }
  echo "🎬 Recording: $tape"
  vhs "$tape"
done

echo ""
echo "✓ Done. GIFs in bin/output/gif/live-*.gif"
