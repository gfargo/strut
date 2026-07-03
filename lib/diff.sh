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

# diff_image_pairs <new_pairs> <old_pairs>
#
# Both args are streams of `service<US>image\n` rows (US = 0x1f). Emits
# the same op stream as diff_env_content — ADD/REMOVE/CHANGE — so callers
# can treat env and image diffs uniformly.
#
# Semantics match the two-argument convention used elsewhere: the first
# argument is the *newer* / *incoming* side (what's on the left of "→")
# when rendered, the second is the *older* / *baseline* side.
#
#   ADD    → present in new only
#   REMOVE → present in old only
#   CHANGE → present in both but differs
diff_image_pairs() {
  local new_pairs="$1"
  local old_pairs="$2"

  declare -A new_map old_map
  local svc img
  while IFS=$'\x1f' read -r svc img; do
    [ -z "$svc" ] && continue
    new_map[$svc]="$img"
  done <<< "$new_pairs"

  while IFS=$'\x1f' read -r svc img; do
    [ -z "$svc" ] && continue
    old_map[$svc]="$img"
  done <<< "$old_pairs"

  local -a all_svcs=()
  for svc in "${!new_map[@]}" "${!old_map[@]}"; do
    all_svcs+=("$svc")
  done
  local sorted
  sorted=$(printf '%s\n' "${all_svcs[@]+"${all_svcs[@]}"}" | sort -u)

  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    local nv="${new_map[$svc]-__STRUT_ABSENT__}"
    local ov="${old_map[$svc]-__STRUT_ABSENT__}"
    if [ "$nv" = "__STRUT_ABSENT__" ] && [ "$ov" != "__STRUT_ABSENT__" ]; then
      printf 'REMOVE\x1f%s\x1f%s\x1f\n' "$svc" "$ov"
    elif [ "$nv" != "__STRUT_ABSENT__" ] && [ "$ov" = "__STRUT_ABSENT__" ]; then
      printf 'ADD\x1f%s\x1f\x1f%s\n' "$svc" "$nv"
    elif [ "$nv" != "$ov" ]; then
      printf 'CHANGE\x1f%s\x1f%s\x1f%s\n' "$svc" "$ov" "$nv"
    fi
  done <<< "$sorted"
}

# diff_images_content <local_content> <remote_content>
#
# Compares extracted service→image maps from two compose files. Thin
# wrapper over diff_image_pairs.
diff_images_content() {
  local local_content="$1"
  local remote_content="$2"

  local loc_img rem_img
  loc_img=$(diff_extract_images "$local_content")
  rem_img=$(diff_extract_images "$remote_content")

  diff_image_pairs "$loc_img" "$rem_img"
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

# ── Volume-path guard helpers ──────────────────────────────────────────────────
#
# diff_extract_volume_vars <compose_content>
#
# Scan service-level volumes: entries for bind-mount host-path prefixes that
# reference an environment variable, e.g.
#   - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
# Emits one variable name per line (no duplicates, sorted).
# Named-volume-only mounts (no leading ${...} or $VAR) are silently skipped.
diff_extract_volume_vars() {
  local content="$1"
  echo "$content" | awk '
    BEGIN { in_volumes = 0; in_services = 0 }
    # Track top-level sections
    /^services:[[:space:]]*$/ { in_services = 1; in_volumes = 0; next }
    /^volumes:[[:space:]]*$/ {
      # Top-level volumes: block — stop scanning for bind-mount vars
      if (!in_services) { in_services = 0; in_volumes = 1; next }
      in_volumes = 1; in_services = 0; next
    }
    # Any new top-level key resets section tracking
    /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {
      if ($0 !~ /^services:/ && $0 !~ /^volumes:/) {
        in_services = 0; in_volumes = 0
      }
    }
    in_services && /^      - / {
      # Service-level volume entry: "      - HOST:CONTAINER[:opts]"
      line = $0
      sub(/^[[:space:]]*- /, "", line)
      # Only process entries that start with a $ (env var reference)
      if (line !~ /^\$/) next
      host = line
      if (host ~ /^\${[^}]+}/) {
        # ${VAR:-default}/... form — extract VAR using POSIX-compatible substr/sub
        varname = substr(host, 3)          # drop "${"
        sub(/[^A-Za-z0-9_].*/, "", varname)  # keep only the identifier chars
        if (length(varname) > 0) vars[varname] = 1
      } else if (host ~ /^\$[A-Za-z_][A-Za-z0-9_]*/) {
        varname = substr(host, 2)
        sub(/[^A-Za-z0-9_].*/, "", varname)
        vars[varname] = 1
      }
    }
    END {
      for (v in vars) print v
    }
  ' | sort -u
}

# diff_extract_named_volumes <compose_content>
#
# Emits the top-level named-volume keys from a docker-compose.yml, one per line.
# These are the keys directly under the top-level `volumes:` block (not
# service-level volume mappings).
diff_extract_named_volumes() {
  local content="$1"
  echo "$content" | awk '
    /^volumes:[[:space:]]*$/ { in_vol = 1; next }
    in_vol && /^[^[:space:]]/ { in_vol = 0; next }
    in_vol && /^  [A-Za-z0-9_.-]+:/ {
      name = $0
      sub(/^  /, "", name)
      sub(/:.*$/, "", name)
      print name
    }
  ' | sort -u
}

# diff_detect_destructive <env_diff_tsv> <compose_content>
#
# Given the \x1f-delimited rows from diff_env_content plus local compose
# content, emit the subset of rows whose key is either:
#   (a) referenced in a volumes: host-path prefix in the compose file, OR
#   (b) matches a known dangerous name heuristic:
#         *_DATA_DIR, *_DATA_PATH, PGDATA, INSTALL_DIR, *_PATH (as suffix)
#   (c) COMPOSE_PROJECT_NAME (orphans running compose project on rename)
# Same \x1f row format so callers can reuse the standard renderers.
diff_detect_destructive() {
  local env_diff="$1"
  local compose_content="$2"

  [ -z "$env_diff" ] && return 0

  # Build set of volume-referencing vars from compose
  local vol_vars
  vol_vars=$(diff_extract_volume_vars "$compose_content")

  local key kind
  while IFS=$'\x1f' read -r kind key rest; do
    [ -z "$kind" ] && continue
    # Check (c): COMPOSE_PROJECT_NAME
    if [ "$key" = "COMPOSE_PROJECT_NAME" ]; then
      printf '%s\x1f%s\x1f%s\n' "$kind" "$key" "$rest"
      continue
    fi
    # Check (a): key referenced in a volumes: host-path prefix
    local matched=false
    while IFS= read -r vv; do
      if [ "$key" = "$vv" ]; then
        matched=true
        break
      fi
    done <<< "$vol_vars"
    if [ "$matched" = "true" ]; then
      printf '%s\x1f%s\x1f%s\n' "$kind" "$key" "$rest"
      continue
    fi
    # Check (b): name heuristic
    if _diff_is_volume_heuristic_var "$key"; then
      printf '%s\x1f%s\x1f%s\n' "$kind" "$key" "$rest"
    fi
  done <<< "$env_diff"
}

# _diff_is_volume_heuristic_var <varname>
# Returns 0 if the variable name matches a heuristic for volume/path vars.
_diff_is_volume_heuristic_var() {
  local v="$1"
  case "$v" in
    PGDATA|INSTALL_DIR|DATA_DIR|DATA_PATH) return 0 ;;
    *_DATA_DIR|*_DATA_PATH|*_PATH) return 0 ;;
  esac
  return 1
}

# diff_detect_volume_renames <local_compose> <remote_compose>
#
# Detect named-volume additions/removals between two compose files.
# Emits rows in the same ADD/REMOVE/CHANGE format:
#   ADD\x1f<vol_name>\x1f\x1f(new named volume)
#   REMOVE\x1f<vol_name>\x1f(removed named volume)\x1f
# A rename shows up as a REMOVE+ADD pair.
diff_detect_volume_renames() {
  local local_compose="$1"
  local remote_compose="$2"

  local local_vols remote_vols
  local_vols=$(diff_extract_named_volumes "$local_compose")
  remote_vols=$(diff_extract_named_volumes "$remote_compose")

  # Build lookup maps
  declare -A local_map remote_map
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    local_map[$v]=1
  done <<< "$local_vols"

  while IFS= read -r v; do
    [ -z "$v" ] && continue
    remote_map[$v]=1
  done <<< "$remote_vols"

  # Emit changes (sorted)
  local -a all_vols=()
  for v in "${!local_map[@]}" "${!remote_map[@]}"; do
    all_vols+=("$v")
  done
  local sorted
  sorted=$(printf '%s\n' "${all_vols[@]+"${all_vols[@]}"}" | sort -u)

  while IFS= read -r v; do
    [ -z "$v" ] && continue
    local in_local="${local_map[$v]-}"
    local in_remote="${remote_map[$v]-}"
    if [ -n "$in_local" ] && [ -z "$in_remote" ]; then
      printf 'ADD\x1f%s\x1f\x1f(new named volume)\n' "$v"
    elif [ -z "$in_local" ] && [ -n "$in_remote" ]; then
      printf 'REMOVE\x1f%s\x1f(removed named volume)\x1f\n' "$v"
    fi
    # Identical → no output
  done <<< "$sorted"
}

# _diff_render_destructive_text <tsv_lines>
#
# Renders the data-destructive changes section with a prominent warning header.
# Uses RED/YELLOW color codes (already sourced from utils.sh by the entrypoint).
_diff_render_destructive_text() {
  local tsv="$1"
  [ -z "$tsv" ] && return 0

  local count
  count=$(printf '%s\n' "$tsv" | grep -c .)

  local RED="${RED:-\033[0;31m}"
  local YELLOW="${YELLOW:-\033[1;33m}"
  local NC="${NC:-\033[0m}"

  printf '\n'
  printf '%s\n' "${RED}⚠  DATA-DESTRUCTIVE CHANGES ($count)${NC}"
  printf '   Changes to volume-defining vars or named volumes will repoint\n'
  printf '   data directories — containers may start with a blank database.\n'

  local kind key old new
  while IFS=$'\x1f' read -r kind key old new; do
    [ -z "$kind" ] && continue
    case "$kind" in
      ADD)    printf '%s  + %s=%s%s\n'         "$YELLOW" "$key" "$new" "$NC" ;;
      REMOVE) printf '%s  - %s%s\n'            "$YELLOW" "$key" "$NC" ;;
      CHANGE) printf '%s  ~ %s: %s → %s%s\n'  "$YELLOW" "$key" "$old" "$new" "$NC" ;;
    esac
  done <<< "$tsv"
}

# diff_warn_env_divergence <stack> <env_file> <stack_dir>
#
# Warns (non-fatal) when the resolved env file differs from the host's
# active .env for volume-defining vars. This catches the "wrong file entirely"
# case: e.g., deploying with .prod.env while the host actually runs from .env
# with different INSTALL_DIR. The volguard handles same-file value changes;
# this function handles the file-identity mismatch.
#
# Skips silently when:
#   - No VPS_HOST (local-only stack)
#   - Remote fetch fails (non-blocking)
#   - The resolved file IS the stack .env (no divergence possible)
#   - No volume-defining vars differ
diff_warn_env_divergence() {
  local stack="$1"
  local env_file="$2"
  local stack_dir="$3"

  # Only meaningful when deploying to a remote VPS
  local vps_host="${VPS_HOST:-}"
  [ -n "$vps_host" ] || return 0

  # If the resolved file is already the stack-level .env, there's no
  # secondary file to diverge from.
  local basename_env
  basename_env=$(basename "$env_file")
  [ "$basename_env" != ".env" ] || return 0

  # Fetch the host's active stack-level .env (compose auto-load path)
  local deploy_dir
  deploy_dir=$(resolve_deploy_dir)
  local remote_stack_env_path="$deploy_dir/stacks/$stack/.env"
  local remote_stack_env
  remote_stack_env=$(diff_fetch_remote "$remote_stack_env_path" 2>/dev/null) || return 0
  [ -n "$remote_stack_env" ] || return 0

  # Read the local resolved env content
  [ -f "$env_file" ] || return 0
  local local_env_content
  local_env_content=$(cat "$env_file")

  # Diff and check for volume-defining var differences
  local env_diff
  env_diff=$(diff_env_content "$local_env_content" "$remote_stack_env")
  [ -n "$env_diff" ] || return 0

  # Filter to volume-defining vars only
  local vol_diff=""
  local kind key rest
  while IFS=$'\x1f' read -r kind key rest; do
    [ -z "$kind" ] && continue
    if _diff_is_volume_heuristic_var "$key"; then
      vol_diff="${vol_diff:+$vol_diff
}$kind $key"
    fi
  done <<< "$env_diff"

  [ -n "$vol_diff" ] || return 0

  # Emit warning (non-fatal)
  warn "Env divergence: '$basename_env' has different volume vars than the host's active .env"
  warn "  Affected vars: $(echo "$vol_diff" | awk '{print $2}' | tr '\n' ' ')"
  warn "  The host may be running from stacks/$stack/.env with different paths."
  warn "  This is informational — the volguard will catch destructive changes."
  return 0
}
