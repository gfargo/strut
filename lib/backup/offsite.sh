#!/usr/bin/env bash
# ==================================================
# lib/backup/offsite.sh — Offsite backup sync (S3 / R2 / B2)
# ==================================================
# Pushes backup artefacts to cloud storage after each local backup so the
# VPS disk is no longer a single point of failure. Opt-in via backup.conf:
#
#   BACKUP_OFFSITE=s3              # s3 | r2 | b2 | none (default: none)
#   BACKUP_OFFSITE_BUCKET=my-bkps
#   BACKUP_OFFSITE_PREFIX=my-stack # default: the stack name
#   BACKUP_OFFSITE_RETENTION_DAYS=90
#
# Providers:
#   s3  → AWS CLI, credentials via env/IAM/~/.aws
#   r2  → AWS CLI against a Cloudflare R2 endpoint (R2_* env vars)
#   b2  → Backblaze b2 CLI with B2_APPLICATION_KEY* env vars
#
# Design notes:
# - Sync failures warn() but never abort the local backup — the whole point
#   is defense in depth, not a hard dependency.
# - `offsite_enabled` is the single source of truth for whether to sync.
# - The remote key layout is `<prefix>/<basename>`. No directory traversal
#   inside the bucket; operators use separate buckets for separate stacks
#   if they want isolation.

set -euo pipefail

# ── Config helpers ────────────────────────────────────────────────────────────

# offsite_provider
#   Emits the configured provider (s3|r2|b2|none). Lower-cased.
offsite_provider() {
  local p="${BACKUP_OFFSITE:-none}"
  printf '%s' "$p" | tr '[:upper:]' '[:lower:]'
}

# offsite_enabled
#   Returns 0 if offsite sync is configured and its CLI is available, else 1.
#   Why the CLI check here: if BACKUP_OFFSITE=s3 but aws isn't installed,
#   we treat it as disabled rather than failing every backup. The missing
#   CLI is warned about once so operators notice.
offsite_enabled() {
  local provider
  provider=$(offsite_provider)
  case "$provider" in
    none|"") return 1 ;;
    s3|r2)
      command -v aws >/dev/null 2>&1 || {
        warn "BACKUP_OFFSITE=$provider but 'aws' CLI not found; offsite sync disabled"
        return 1
      }
      ;;
    b2)
      command -v b2 >/dev/null 2>&1 || {
        warn "BACKUP_OFFSITE=b2 but 'b2' CLI not found; offsite sync disabled"
        return 1
      }
      ;;
    *)
      warn "Unknown BACKUP_OFFSITE value: $provider (expected s3|r2|b2|none)"
      return 1
      ;;
  esac
  if [ -z "${BACKUP_OFFSITE_BUCKET:-}" ]; then
    warn "BACKUP_OFFSITE=$provider set but BACKUP_OFFSITE_BUCKET is empty; offsite sync disabled"
    return 1
  fi
  return 0
}

# _offsite_prefix <stack>
_offsite_prefix() {
  local stack="$1"
  echo "${BACKUP_OFFSITE_PREFIX:-$stack}"
}

# _offsite_remote_url <stack> <filename>
#   Builds the remote URL for a given local backup basename. S3/R2 use
#   s3://bucket/prefix/filename; B2 uses b2://bucket/prefix/filename
#   (surface form — the b2 CLI takes a separate bucket arg).
_offsite_remote_url() {
  local stack="$1" filename="$2"
  local prefix provider
  prefix=$(_offsite_prefix "$stack")
  provider=$(offsite_provider)
  case "$provider" in
    s3|r2) echo "s3://${BACKUP_OFFSITE_BUCKET}/${prefix}/${filename}" ;;
    b2)    echo "b2://${BACKUP_OFFSITE_BUCKET}/${prefix}/${filename}" ;;
    *)     echo "" ;;
  esac
}

# _offsite_aws_opts
#   Adds --endpoint-url for R2 so `aws s3 cp` can talk to Cloudflare's
#   S3-compatible API. For vanilla S3 we return an empty string.
_offsite_aws_opts() {
  local provider
  provider=$(offsite_provider)
  if [ "$provider" = "r2" ]; then
    # R2 endpoint requires R2_ACCOUNT_ID. We don't inject credentials —
    # operators set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or R2_*) in
    # their env and let the aws CLI pick them up.
    local acct="${R2_ACCOUNT_ID:-}"
    if [ -n "$acct" ]; then
      echo "--endpoint-url=https://${acct}.r2.cloudflarestorage.com"
    fi
  fi
}

# ── Sync ──────────────────────────────────────────────────────────────────────

# offsite_sync_file <stack> <local_path>
#
# Uploads one backup artefact. Non-fatal: any failure warns and returns 1
# so the surrounding backup flow continues.
offsite_sync_file() {
  local stack="$1" local_path="$2"
  offsite_enabled || return 1
  [ -f "$local_path" ] || { warn "offsite sync: $local_path does not exist"; return 1; }

  local filename provider remote_url
  filename=$(basename "$local_path")
  provider=$(offsite_provider)
  remote_url=$(_offsite_remote_url "$stack" "$filename")

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "  [dry-run] offsite sync → $remote_url"
    return 0
  fi

  log "Offsite sync → $remote_url"
  case "$provider" in
    s3|r2)
      local opts
      opts=$(_offsite_aws_opts)
      # shellcheck disable=SC2086
      if aws $opts s3 cp "$local_path" "$remote_url" >/dev/null 2>&1; then
        ok "Offsite sync complete: $filename"
        return 0
      fi
      warn "Offsite sync failed for $filename (aws s3 cp exit non-zero)"
      return 1
      ;;
    b2)
      local prefix
      prefix=$(_offsite_prefix "$stack")
      if b2 upload-file "${BACKUP_OFFSITE_BUCKET}" "$local_path" "${prefix}/${filename}" >/dev/null 2>&1; then
        ok "Offsite sync complete: $filename"
        return 0
      fi
      warn "Offsite sync failed for $filename (b2 upload-file exit non-zero)"
      return 1
      ;;
  esac
  return 1
}

# offsite_sync_latest <stack> <pattern>
#
# Finds the newest file in the stack's backup dir matching <pattern>
# (glob, e.g. `postgres-*.sql`) and syncs it. Called from cmd.sh after
# each successful backup_<type> so we don't need to plumb the exact
# output filename through every backup function.
#
# No-op when offsite is disabled or no match is found.
offsite_sync_latest() {
  local stack="$1" pattern="$2"
  offsite_enabled || return 0

  local dir latest
  dir=$(_backup_dir "$stack")
  [ -d "$dir" ] || return 0

  # Newest match wins. Null-glob via conditional guard.
  latest=$(ls -t "$dir"/$pattern 2>/dev/null | head -1)
  [ -z "$latest" ] && return 0

  # Non-fatal — never abort the enclosing backup if sync fails.
  offsite_sync_file "$stack" "$latest" || true
}

# offsite_sync_all <stack>
#
# Walks the local backup directory and uploads every file. Intended for
# initial backfill or after a provider was newly configured. Emits a
# per-file result; aggregate exit is 0 if at least one file succeeded,
# 1 if all failed.
offsite_sync_all() {
  local stack="$1"
  offsite_enabled || { warn "Offsite not configured; nothing to sync"; return 1; }

  local dir
  dir=$(_backup_dir "$stack")
  if [ ! -d "$dir" ]; then
    warn "Backup dir not found: $dir"
    return 1
  fi

  local total=0 ok_count=0 fail_count=0
  local f
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    # Skip metadata/sidecar files — those travel with a restore operation,
    # not as independent artefacts.
    case "$f" in
      *.meta|*.json) continue ;;
    esac
    total=$((total + 1))
    if offsite_sync_file "$stack" "$f"; then
      ok_count=$((ok_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  done

  if [ "$total" -eq 0 ]; then
    warn "No backup files found in $dir"
    return 1
  fi
  log "Offsite sync: $ok_count/$total succeeded ($fail_count failed)"
  [ "$ok_count" -gt 0 ]
}

# ── List / Restore ────────────────────────────────────────────────────────────

# offsite_list <stack>
#
# Lists objects under the stack's prefix. Output format is provider-native;
# operators read this for ad-hoc inspection — we don't try to reshape it.
offsite_list() {
  local stack="$1"
  offsite_enabled || { warn "Offsite not configured"; return 1; }

  local provider prefix
  provider=$(offsite_provider)
  prefix=$(_offsite_prefix "$stack")

  case "$provider" in
    s3|r2)
      local opts
      opts=$(_offsite_aws_opts)
      # shellcheck disable=SC2086
      aws $opts s3 ls "s3://${BACKUP_OFFSITE_BUCKET}/${prefix}/" 2>/dev/null
      ;;
    b2)
      b2 ls "${BACKUP_OFFSITE_BUCKET}" "${prefix}" 2>/dev/null
      ;;
  esac
}

# offsite_restore <stack> <filename> [local_dest_dir]
#
# Downloads a single object from offsite back into the local backup dir
# (or a caller-supplied directory). `<filename>` is the basename (e.g.
# `postgres-20260420-143000.sql`) — the prefix is resolved automatically.
offsite_restore() {
  local stack="$1" filename="$2" dest_dir="${3:-}"
  offsite_enabled || { warn "Offsite not configured"; return 1; }

  [ -z "$filename" ] && { fail "Usage: offsite_restore <stack> <filename>"; return 1; }

  local target_dir
  if [ -n "$dest_dir" ]; then
    target_dir="$dest_dir"
  else
    target_dir=$(_backup_dir "$stack")
  fi
  mkdir -p "$target_dir"

  local provider prefix remote_url target
  provider=$(offsite_provider)
  prefix=$(_offsite_prefix "$stack")
  remote_url=$(_offsite_remote_url "$stack" "$filename")
  target="$target_dir/$filename"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "  [dry-run] offsite restore $remote_url → $target"
    return 0
  fi

  log "Offsite restore $remote_url → $target"
  case "$provider" in
    s3|r2)
      local opts
      opts=$(_offsite_aws_opts)
      # shellcheck disable=SC2086
      aws $opts s3 cp "$remote_url" "$target" >/dev/null 2>&1 || {
        fail "Offsite restore failed (aws s3 cp)"
        return 1
      }
      ;;
    b2)
      b2 download-file-by-name "${BACKUP_OFFSITE_BUCKET}" "${prefix}/${filename}" "$target" >/dev/null 2>&1 || {
        fail "Offsite restore failed (b2 download-file-by-name)"
        return 1
      }
      ;;
  esac
  ok "Restored: $target"
}

# ── Status ────────────────────────────────────────────────────────────────────

# offsite_status
#   Prints a short config summary. Purely informational; exit is 0 whether
#   or not sync is enabled (caller uses offsite_enabled for the decision).
offsite_status() {
  local provider bucket prefix
  provider=$(offsite_provider)
  bucket="${BACKUP_OFFSITE_BUCKET:-<unset>}"
  prefix="${BACKUP_OFFSITE_PREFIX:-<stack-name>}"

  echo ""
  echo "Offsite backup configuration:"
  echo "  Provider:  $provider"
  echo "  Bucket:    $bucket"
  echo "  Prefix:    $prefix"
  echo "  Retention: ${BACKUP_OFFSITE_RETENTION_DAYS:-90} days"
  echo ""
  if offsite_enabled 2>/dev/null; then
    ok "Offsite sync is ENABLED"
  else
    warn "Offsite sync is DISABLED (check BACKUP_OFFSITE/BACKUP_OFFSITE_BUCKET and CLI availability)"
  fi
}
