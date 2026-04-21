#!/usr/bin/env bash
# ==================================================
# lib/diff.sh — Semantic diff engine for env + compose files
# ==================================================
# Used by `strut <stack> diff` (local → VPS preview) and by the planned
# `rollback diff` command (snapshot A → snapshot B). Both callers want the
# same thing: structured diffs over env KEY=value lines and docker-compose
# `image:` declarations, rendered as text or JSON.
#
# Keeping these helpers pure (no side effects, no SSH) lets tests pass
# literal strings in without stubbing the network.

set -euo pipefail

# ── Internal: normalize env content ───────────────────────────────────────────
#
# _diff_normalize_env <content>
#   Emits `KEY=VALUE` lines:
#   - Comments and blank lines dropped
#   - Surrounding whitespace trimmed
#   - Surrounding "..." or '...' stripped from the value
#   - Keys sorted (deterministic diff order)
_diff_normalize_env() {
  local content="$1"
  echo "$content" | awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      # Split on first =
      idx = index($0, "=")
      if (idx == 0) next
      key = substr($0, 1, idx - 1)
      val = substr($0, idx + 1)
      # Trim key whitespace
      sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
      # Strip export prefix if present
      sub(/^export[[:space:]]+/, "", key)
      # Strip surrounding quotes from value
      if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
      else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val) - 2) }
      # Strip trailing whitespace from value
      sub(/[[:space:]]+$/, "", val)
      print key "=" val
    }
  ' | sort
}

# diff_env_content <local_content> <remote_content>
#
# Compares two env-file contents. Emits one row per changed key, fields
# separated by ASCII unit separator (0x1f). A non-whitespace delimiter is
# used because `read -r` with a whitespace IFS collapses consecutive
# empty fields.
#
#   ADD\x1f<key>\x1f\x1f<new_value>
#   REMOVE\x1f<key>\x1f<old_value>\x1f
#   CHANGE\x1f<key>\x1f<old_value>\x1f<new_value>
#
# No output if the contents are equivalent. Exit code is always 0 — callers
# check line count to decide if anything changed.
diff_env_content() {
  local local_content="$1"
  local remote_content="$2"

  local loc_norm rem_norm
  loc_norm=$(_diff_normalize_env "$local_content")
  rem_norm=$(_diff_normalize_env "$remote_content")

  # Build associative arrays keyed by env var name
  declare -A loc_map rem_map
  local line key val
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    val="${line#*=}"
    loc_map[$key]="$val"
  done <<< "$loc_norm"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    val="${line#*=}"
    rem_map[$key]="$val"
  done <<< "$rem_norm"

  # Emit changes in sorted key order (union of keys)
  local -a all_keys=()
  for key in "${!loc_map[@]}" "${!rem_map[@]}"; do
    all_keys+=("$key")
  done
  # Deduplicate + sort
  local sorted_keys
  sorted_keys=$(printf '%s\n' "${all_keys[@]}" | sort -u)

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    local lv="${loc_map[$key]-__STRUT_ABSENT__}"
    local rv="${rem_map[$key]-__STRUT_ABSENT__}"
    if [ "$lv" = "__STRUT_ABSENT__" ] && [ "$rv" != "__STRUT_ABSENT__" ]; then
      # On remote, not in local → will be REMOVED by deploy
      printf 'REMOVE\x1f%s\x1f%s\x1f\n' "$key" "$rv"
    elif [ "$lv" != "__STRUT_ABSENT__" ] && [ "$rv" = "__STRUT_ABSENT__" ]; then
      printf 'ADD\x1f%s\x1f\x1f%s\n' "$key" "$lv"
    elif [ "$lv" != "$rv" ]; then
      printf 'CHANGE\x1f%s\x1f%s\x1f%s\n' "$key" "$rv" "$lv"
    fi
  done <<< "$sorted_keys"
}

# ── Compose image extraction ──────────────────────────────────────────────────
#
# diff_extract_images <compose_content>
#
# Emits `service<TAB>image` lines by scanning a docker-compose.yml file for
# `image:` declarations nested under services. We don't do full YAML parsing
# (no yq dependency) — we track the current service via indent and the most
# recent `services:` / `<name>:` pair. This handles the overwhelmingly
# common case where each service has an `image:` key, optionally with
# registry/tag.
diff_extract_images() {
  local content="$1"
  # POSIX-compatible: no 3-arg match() (that's gawk-only). We test with
  # regex and parse the captured portion via substr/sub.
  echo "$content" | awk '
    /^services:[[:space:]]*$/ { in_services = 1; next }
    in_services && /^[^[:space:]]/ { in_services = 0 }
    in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      svc = $0
      sub(/^  /, "", svc)
      sub(/:[[:space:]]*$/, "", svc)
      current_service = svc
      next
    }
    in_services && current_service != "" && /^    image:[[:space:]]*.+$/ {
      img = $0
      sub(/^    image:[[:space:]]*/, "", img)
      sub(/[[:space:]]+$/, "", img)
      # Strip surrounding quotes
      gsub(/^["\x27]/, "", img); gsub(/["\x27]$/, "", img)
      printf "%s\x1f%s\n", current_service, img
    }
  '
}

# diff_images_content <local_content> <remote_content>
#
# Compares extracted service→image maps. Emits TSV:
#   ADD\t<service>\t\t<new_image>
#   REMOVE\t<service>\t<old_image>\t
#   CHANGE\t<service>\t<old_image>\t<new_image>
diff_images_content() {
  local local_content="$1"
  local remote_content="$2"

  local loc_img rem_img
  loc_img=$(diff_extract_images "$local_content")
  rem_img=$(diff_extract_images "$remote_content")

  declare -A loc_map rem_map
  local svc img
  while IFS=$'\x1f' read -r svc img; do
    [ -z "$svc" ] && continue
    loc_map[$svc]="$img"
  done <<< "$loc_img"

  while IFS=$'\x1f' read -r svc img; do
    [ -z "$svc" ] && continue
    rem_map[$svc]="$img"
  done <<< "$rem_img"

  local -a all_svcs=()
  for svc in "${!loc_map[@]}" "${!rem_map[@]}"; do
    all_svcs+=("$svc")
  done
  local sorted
  sorted=$(printf '%s\n' "${all_svcs[@]}" | sort -u)

  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    local lv="${loc_map[$svc]-__STRUT_ABSENT__}"
    local rv="${rem_map[$svc]-__STRUT_ABSENT__}"
    if [ "$lv" = "__STRUT_ABSENT__" ] && [ "$rv" != "__STRUT_ABSENT__" ]; then
      printf 'REMOVE\x1f%s\x1f%s\x1f\n' "$svc" "$rv"
    elif [ "$lv" != "__STRUT_ABSENT__" ] && [ "$rv" = "__STRUT_ABSENT__" ]; then
      printf 'ADD\x1f%s\x1f\x1f%s\n' "$svc" "$lv"
    elif [ "$lv" != "$rv" ]; then
      printf 'CHANGE\x1f%s\x1f%s\x1f%s\n' "$svc" "$rv" "$lv"
    fi
  done <<< "$sorted"
}

# ── Remote fetchers (thin SSH wrappers) ───────────────────────────────────────
#
# diff_fetch_remote <remote_path>
# Cats a file on the VPS. Uses VPS_HOST/VPS_USER/SSH_KEY/SSH_PORT from the
# current env (typically loaded from the stack's env file). Prints content
# to stdout; empty output if the file doesn't exist.
diff_fetch_remote() {
  local remote_path="$1"
  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "${SSH_PORT:-22}" -k "${SSH_KEY:-}" --batch)
  local user="${VPS_USER:-ubuntu}"
  local host="${VPS_HOST:-}"
  [ -z "$host" ] && return 1
  # shellcheck disable=SC2086
  ssh $ssh_opts "$user@$host" "cat $remote_path 2>/dev/null" || true
}

# ── Renderers ─────────────────────────────────────────────────────────────────
#
# _diff_render_section_text <title> <tsv_lines>
# Renders one section of the diff in operator-friendly text form.
_diff_render_section_text() {
  local title="$1"
  local tsv="$2"
  [ -z "$tsv" ] && return 0

  local count
  count=$(printf '%s\n' "$tsv" | grep -c .)
  echo ""
  echo "$title ($count change$([ "$count" -ne 1 ] && echo s))"

  local kind key old new
  while IFS=$'\x1f' read -r kind key old new; do
    [ -z "$kind" ] && continue
    case "$kind" in
      ADD)    printf '  + %s=%s\n' "$key" "$new" ;;
      REMOVE) printf '  - %s\n' "$key" ;;
      CHANGE) printf '  ~ %s: %s → %s\n' "$key" "$old" "$new" ;;
    esac
  done <<< "$tsv"
}

# _diff_render_section_json <json_key> <tsv_lines>
# Emits one JSON array via out_json_* helpers (caller is inside an object).
_diff_render_section_json() {
  local json_key="$1"
  local tsv="$2"

  out_json_array "$json_key"
  [ -z "$tsv" ] && { out_json_close_array; return 0; }

  local kind key old new
  while IFS=$'\x1f' read -r kind key old new; do
    [ -z "$kind" ] && continue
    out_json_object
      out_json_field "op" "$kind"
      out_json_field "key" "$key"
      [ -n "$old" ] && out_json_field "old" "$old"
      [ -n "$new" ] && out_json_field "new" "$new"
    out_json_close_object
  done <<< "$tsv"
  out_json_close_array
}
