#!/usr/bin/env bash
# ==================================================
# record.sh — Render VHS tapes into GIFs/PNGs
# ==================================================
# Usage:
#   ./bin/record.sh                    # Render all tapes
#   ./bin/record.sh tapes/hero.tape    # Render a single tape
#
# Output lands in bin/output/gif/ and bin/output/png/
# GIFs are automatically optimized after rendering.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAPES_DIR="$SCRIPT_DIR/tapes"
OUTPUT_DIR="$SCRIPT_DIR/output"

# ── Preflight checks ─────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  command -v vhs >/dev/null 2>&1 || missing+=("vhs")
  command -v gifsicle >/dev/null 2>&1 || missing+=("gifsicle")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "❌ Missing dependencies: ${missing[*]}"
    echo ""
    echo "Install with:"
    echo "  brew install ${missing[*]}"
    exit 1
  fi
}

# ── Ensure output directories exist ──────────────────────────────────────────

ensure_dirs() {
  mkdir -p "$OUTPUT_DIR/gif"
  mkdir -p "$OUTPUT_DIR/png"
}

# ── Render a single tape ─────────────────────────────────────────────────────

render_tape() {
  local tape="$1"
  local tape_name
  tape_name="$(basename "$tape" .tape)"

  echo "🎬 Recording: $tape_name"
  
  # VHS resolves output paths relative to the tape file's directory.
  # Run from the tapes dir so ../output/... resolves to bin/output/
  (
    cd "$TAPES_DIR"
    vhs "$(basename "$tape")"
  )

  echo "✓ Done: $tape_name"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_deps
  ensure_dirs

  if [[ $# -gt 0 ]]; then
    # Render specific tape(s)
    for tape in "$@"; do
      if [[ "$tape" = /* ]]; then
        render_tape "$tape"
      else
        render_tape "$SCRIPT_DIR/$tape"
      fi
    done
  else
    # Render all tapes
    local tape_count=0
    for tape in "$TAPES_DIR"/*.tape; do
      [[ -f "$tape" ]] || continue
      render_tape "$tape"
      tape_count=$((tape_count + 1))
    done

    if [[ $tape_count -eq 0 ]]; then
      echo "⚠ No .tape files found in $TAPES_DIR"
      exit 0
    fi

    echo ""
    echo "📼 Rendered $tape_count tape(s)"
  fi

  # Optimize all GIFs (lossy + reduced palette — best balance of size and quality)
  echo ""
  "$SCRIPT_DIR/optimize.sh" --lossy --colors 64
}

main "$@"
