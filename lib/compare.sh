#!/usr/bin/env bash
# ==================================================
# lib/compare.sh — Shared artifact normalization/comparison core
# ==================================================
# Pure helpers used by both diff and drift so each command compares the same
# content with the same normalization rules.
# Requires: no sourced strut modules; sha256sum, awk, and sed on PATH.

set -euo pipefail

# compare_normalize_env <content>
# Emits deterministic KEY=VALUE rows, ignoring comments, blank lines, export
# prefixes, surrounding quotes, and key/trailing whitespace.
compare_normalize_env() {
  local content="$1"
  printf '%s\n' "$content" | awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      idx = index($0, "=")
      if (idx == 0) next
      key = substr($0, 1, idx - 1)
      val = substr($0, idx + 1)
      sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
      sub(/^export[[:space:]]+/, "", key)
      if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
      else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val) - 2) }
      sub(/[[:space:]]+$/, "", val)
      print key "=" val
    }
  ' | sort
}

# compare_normalize_artifact <path-or-name> <content>
# Env-shaped artifacts use semantic KV normalization. Other configuration
# files retain byte-significant content apart from CRLF normalization; command
# substitution at callers already makes one trailing newline insignificant.
compare_normalize_artifact() {
  local artifact="$1"
  local content="$2"
  local name
  name=$(basename "$artifact")
  case "$name" in
    .env|*.env|*.env.template) compare_normalize_env "$content" ;;
    *) printf '%s' "$content" | sed 's/\r$//' ;;
  esac
}

# compare_artifact_hash <path-or-name> <content>
compare_artifact_hash() {
  local artifact="$1"
  local content="$2"
  local normalized
  normalized=$(compare_normalize_artifact "$artifact" "$content")
  printf '%s' "$normalized" | sha256sum | awk '{print $1}'
}

# compare_artifacts_equal <path-or-name> <left-content> <right-content>
compare_artifacts_equal() {
  local artifact="$1"
  local left="$2"
  local right="$3"
  [ "$(compare_artifact_hash "$artifact" "$left")" = "$(compare_artifact_hash "$artifact" "$right")" ]
}
