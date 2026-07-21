#!/usr/bin/env bash
# ==================================================
# cmd_gen.sh — Generate-if-absent primitive for tracked, encrypted vars
# ==================================================
# Usage: strut <stack> gen <VAR> [--scope host|stack] [--host <alias>]
#                              [--recipe hex32|uuid] [--dry-run]
#
# Generates a value for VAR exactly once and persists it encrypted at rest,
# so it survives a clean git-redeploy without ever landing in the repo as
# plaintext. Idempotent: if VAR is already present in the target file, this
# is a no-op (the Ansible `password`-lookup idiom).
#
# Complements secrets hydrate/init-secrets (whole-file generation) — `gen`
# is the single-var primitive for values that must be stable across
# redeploys but aren't sourced from a template (e.g. a per-host JWT secret).
# ==================================================
# Requires: lib/utils.sh, lib/topology.sh, lib/cmd_secrets.sh sourced first

set -euo pipefail

_usage_gen() {
  echo ""
  echo "Usage: strut <stack> gen <VAR> [--scope host|stack] [--host <alias>]"
  echo "                             [--recipe hex32|uuid] [--dry-run]"
  echo ""
  echo "Generate a value for VAR once and persist it encrypted at rest."
  echo "If VAR is already present, this is a no-op (safe to re-run)."
  echo ""
  echo "Options:"
  echo "  --scope host|stack   host: env/hosts/<alias>.gen.enc.env (default)"
  echo "                       stack: env/stack.gen.enc.env (shared across hosts)"
  echo "  --host <alias>       Host alias to generate for (default: resolved from"
  echo "                       strut.conf [stacks]/[hosts], or --host on the CLI)"
  echo "  --recipe <name>      hex32 (default, openssl rand -hex 32) or uuid"
  echo "  --dry-run            Preview the would-be var/recipe; writes nothing"
  echo ""
  echo "Storage:"
  echo "  Encrypted with the same age/gpg + .strut-recipients cascade as"
  echo "  'secrets lock/unlock' — safe to commit."
  echo ""
  echo "Examples:"
  echo "  strut my-app gen JWT_SECRET"
  echo "  strut my-app gen SESSION_ID --recipe uuid --host compass"
  echo "  strut my-app gen SHARED_TOKEN --scope stack --dry-run"
  echo ""
}

# _gen_resolve_host_alias <stack> <host_flag>
# Resolution order: explicit --host, the topology target the dispatcher
# already resolved for this invocation (_TOPO_ACTIVE_HOST_ALIAS — covers
# both a plain [stacks] mapping and a CLI --host override), then a direct
# [stacks] lookup (for callers that invoke gen_if_absent without going
# through the strut entrypoint's topology_apply_* dispatch).
_gen_resolve_host_alias() {
  local stack="$1"
  local host_flag="$2"

  if [ -n "$host_flag" ]; then
    echo "$host_flag"
    return 0
  fi

  if [ -n "${_TOPO_ACTIVE_HOST_ALIAS:-}" ]; then
    echo "$_TOPO_ACTIVE_HOST_ALIAS"
    return 0
  fi

  topology_load
  local alias
  alias=$(topology_stack_host_alias "$stack")
  if [ -n "$alias" ]; then
    echo "$alias"
    return 0
  fi

  return 1
}

# _gen_value <recipe>
# Generates a value for the given recipe. Returns 1 for an unknown recipe.
_gen_value() {
  local recipe="$1"
  case "$recipe" in
    hex32)
      openssl rand -hex 32
      ;;
    uuid)
      if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
      else
        _gen_uuid4
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# _gen_uuid4 — RFC 4122 v4 UUID built from openssl rand, for hosts without uuidgen.
_gen_uuid4() {
  local h
  h=$(openssl rand -hex 16)
  local variant_nibble="${h:16:1}" variant
  case "$variant_nibble" in
    0|4|8|c) variant=8 ;;
    1|5|9|d) variant=9 ;;
    2|6|a|e) variant=a ;;
    3|7|b|f) variant=b ;;
  esac
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "$variant" "${h:17:3}" "${h:20:12}"
}

# gen_if_absent (reads CMD_*)
# Core logic for `strut <stack> gen <VAR>`.
gen_if_absent() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local dry_run="${DRY_RUN:-false}"
  local var="" scope="host" host_flag="" recipe="hex32"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope)      scope="${2:-}";  shift 2 ;;
      --scope=*)    scope="${1#--scope=}"; shift ;;
      --host)       host_flag="${2:-}"; shift 2 ;;
      --host=*)     host_flag="${1#--host=}"; shift ;;
      --recipe)     recipe="${2:-}"; shift 2 ;;
      --recipe=*)   recipe="${1#--recipe=}"; shift ;;
      --dry-run)    dry_run=true;    shift ;;
      -*)           fail "Unknown option: $1"; return 1 ;;
      *)            [ -z "$var" ] && var="$1"; shift ;;
    esac
  done

  [ -n "$var" ] || { fail "Usage: strut <stack> gen <VAR> [--scope host|stack] [--host <alias>] [--recipe hex32|uuid] [--dry-run]"; return 1; }
  [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { fail "Invalid VAR '$var' (must be uppercase with underscores, e.g. JWT_SECRET)"; return 1; }

  case "$scope" in
    host|stack) ;;
    *) fail "Unknown --scope '$scope'. Use 'host' or 'stack'."; return 1 ;;
  esac

  case "$recipe" in
    hex32|uuid) ;;
    *) fail "Unknown --recipe '$recipe'. Use 'hex32' or 'uuid'."; return 1 ;;
  esac

  local enc_path
  if [ "$scope" = "stack" ]; then
    enc_path="$stack_dir/env/stack.gen.enc.env"
  else
    local host_alias
    if ! host_alias=$(_gen_resolve_host_alias "$stack" "$host_flag"); then
      fail "Could not resolve a host alias for '$stack'. Pass --host <alias>, map the stack in strut.conf [stacks], or use --scope stack."
      return 1
    fi
    enc_path="$stack_dir/env/hosts/${host_alias}.gen.enc.env"
  fi

  print_banner "Gen"
  log "Stack: $stack | Var: $var | Scope: $scope | Recipe: $recipe"
  log "File: $enc_path"
  echo ""

  if [ "$dry_run" = "true" ]; then
    if [ -f "$enc_path" ]; then
      echo -e "${YELLOW}[DRY-RUN] Would decrypt $enc_path, check for $var, generate via '$recipe' if absent, re-encrypt.${NC}"
    else
      echo -e "${YELLOW}[DRY-RUN] $enc_path does not exist yet — would generate $var via '$recipe' and create it.${NC}"
    fi
    echo -e "${YELLOW}[DRY-RUN] No changes made.${NC}"
    return 0
  fi

  local backend
  if ! backend=$(_secrets_detect_backend); then
    fail "No encryption backend available. Install 'age' (recommended) or 'gpg'."
    return 1
  fi

  mkdir -p "$(dirname "$enc_path")"

  # Decrypted staging copy. Cleaned up explicitly on every return path below
  # rather than via a RETURN/EXIT trap: _secrets_lock/_secrets_unlock each
  # arm their own EXIT/INT/TERM trap on a local temp-file var that goes out
  # of scope the moment they return, so relying on trap chaining here would
  # risk firing a stale trap against an unset variable under `set -u`.
  local tmp_plain
  tmp_plain=$(mktemp "${TMPDIR:-/tmp}/strut-gen-XXXXXX") || { fail "Could not create temp file"; return 1; }
  chmod 600 "$tmp_plain"

  if [ -f "$enc_path" ]; then
    if ! _secrets_unlock --file "$enc_path" --output "$tmp_plain" --backend "$backend" --keep --force; then
      trap - EXIT INT TERM
      rm -f "$tmp_plain"
      fail "Failed to decrypt $enc_path"
      return 1
    fi
    trap - EXIT INT TERM

    if grep -q "^${var}=" "$tmp_plain" 2>/dev/null; then
      rm -f "$tmp_plain"
      ok "$var already present in $enc_path — no-op"
      return 0
    fi
  fi

  local value
  if ! value=$(_gen_value "$recipe"); then
    rm -f "$tmp_plain"
    fail "Failed to generate value for recipe '$recipe'"
    return 1
  fi
  printf '%s=%s\n' "$var" "$value" >> "$tmp_plain"

  if ! _secrets_lock --file "$tmp_plain" --output "$enc_path" --backend "$backend" --force; then
    trap - EXIT INT TERM
    rm -f "$tmp_plain"
    fail "Failed to encrypt $enc_path"
    return 1
  fi
  trap - EXIT INT TERM
  rm -f "$tmp_plain"

  ok "Generated $var ($recipe) -> $enc_path"
}

# cmd_gen — dispatch entrypoint for `strut <stack> gen <VAR> ...`
cmd_gen() {
  gen_if_absent "$@"
}
