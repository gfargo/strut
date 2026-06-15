#!/usr/bin/env bash
# ==================================================
# optimize.sh — GIF optimization via gifsicle
# ==================================================
# Rewrites GIFs in-place with inter-frame transparency optimization.
# Default mode is lossless (-O3). Use --lossy for aggressive reduction.
#
# Usage:
#   ./bin/optimize.sh                       # Lossless optimize all GIFs
#   ./bin/optimize.sh --lossy               # Lossy optimize all GIFs (~30-50% smaller)
#   ./bin/optimize.sh path/to/file.gif      # Optimize a specific file
#   ./bin/optimize.sh --lossy file.gif      # Lossy optimize a specific file
#   ./bin/optimize.sh --colors 128 file.gif # Reduce color palette (lossy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIF_DIR="$SCRIPT_DIR/output/gif"

# ── Parse flags ───────────────────────────────────────────────────────────────
LOSSY=""
COLORS=""
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lossy)   LOSSY="--lossy=80"; shift ;;
    --lossy=*) LOSSY="--lossy=${1#*=}"; shift ;;
    --colors)  COLORS="--colors $2"; shift 2 ;;
    --colors=*) COLORS="--colors ${1#*=}"; shift ;;
    *)         FILES+=("$1"); shift ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────

if ! command -v gifsicle >/dev/null 2>&1; then
  echo "⚠ gifsicle not found — skipping optimization"
  echo "  Install: brew install gifsicle"
  exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

numfmt_size() {
  local bytes=$1
  if [[ $bytes -ge 1048576 ]]; then
    printf "%.1fMB" "$(echo "scale=1; $bytes / 1048576" | bc)"
  elif [[ $bytes -ge 1024 ]]; then
    echo "$(( bytes / 1024 ))KB"
  else
    echo "${bytes}B"
  fi
}

optimize_file() {
  local file="$1"
  local before after pct

  before=$(stat -f%z "$file" 2>/dev/null || stat --printf="%s" "$file" 2>/dev/null)

  # Build gifsicle command
  local cmd="gifsicle -O3"
  [[ -n "$LOSSY" ]] && cmd="$cmd $LOSSY"
  [[ -n "$COLORS" ]] && cmd="$cmd $COLORS"
  cmd="$cmd --batch $file"

  eval "$cmd"

  after=$(stat -f%z "$file" 2>/dev/null || stat --printf="%s" "$file" 2>/dev/null)

  if [[ $before -gt 0 ]]; then
    pct=$(( (before - after) * 100 / before ))
    local mode="lossless"
    [[ -n "$LOSSY" || -n "$COLORS" ]] && mode="lossy"
    echo "  ✓ $(basename "$file"): $(numfmt_size "$before") → $(numfmt_size "$after") (-${pct}%) [$mode]"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  if [[ ${#FILES[@]} -gt 0 ]]; then
    for file in "${FILES[@]}"; do
      [[ -f "$file" ]] || { echo "⚠ Not found: $file"; continue; }
      optimize_file "$file"
    done
  else
    local count=0
    for file in "$GIF_DIR"/*.gif; do
      [[ -f "$file" ]] || continue
      optimize_file "$file"
      count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
      echo "  (no GIFs to optimize)"
    else
      echo "🗜  Optimized $count GIF(s)"
    fi
  fi
}

_label="lossless"
[[ -n "$LOSSY" || -n "$COLORS" ]] && _label="lossy"
echo "🗜  Optimizing GIFs ($_label)..."
main
