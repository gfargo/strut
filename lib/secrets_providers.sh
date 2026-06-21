#!/usr/bin/env bash
# ==================================================
# secrets_providers.sh — Pluggable secret sources for `secrets hydrate`
# ==================================================
# Lets secret values live in an external manager (Vaultwarden/Bitwarden, the
# stdout of a command, or a file) instead of plaintext on disk. A template
# value written as "<scheme>://<ref>" is resolved at hydrate time; any other
# value is copied through verbatim, so the default behaviour is unchanged.
#
# Reference syntax (in a .env template):
#   KEY=vault://<item-name>     Vaultwarden / Bitwarden item, via the `bw` CLI
#   KEY=exec://<command>        Stdout of a shell command (e.g. a cloud SM CLI)
#   KEY=file://<path>           Contents of a file (e.g. /run/secrets/<x>)
#   KEY=plain-value             Literal — copied as-is (default)
#
# Add a provider: define `secrets_provider__<scheme>()` taking the ref string
# on $1 and printing the resolved value to stdout (and `fail`ing on error);
# optionally a `secrets_provider__<scheme>_check()` that pre-flights tooling
# and credentials. Then add <scheme> to SECRETS_PROVIDERS below.
#
# Requires: lib/utils.sh sourced first (fail/warn/log/ok)
# Provides: secrets_reference_scheme, secrets_is_reference,
#           secrets_reference_target, secrets_provider_available,
#           secrets_resolve_reference
# ==================================================

set -euo pipefail

# Registered provider schemes (space-separated). Only these schemes are treated
# as references — a normal value like "postgres://..." stays literal.
SECRETS_PROVIDERS="${SECRETS_PROVIDERS:-vault exec file}"

# secrets_reference_scheme <value>
# If <value> is "<scheme>://..." and <scheme> is registered, echo the scheme
# and return 0. Otherwise echo nothing and return 1 (the value is literal).
secrets_reference_scheme() {
  local value="$1"
  local scheme
  if [[ "$value" =~ ^([a-z][a-z0-9+.-]*):// ]]; then
    scheme="${BASH_REMATCH[1]}"
    case " $SECRETS_PROVIDERS " in
      *" $scheme "*) echo "$scheme"; return 0 ;;
    esac
  fi
  return 1
}

# secrets_is_reference <value> — 0 if the value is a resolvable reference.
secrets_is_reference() {
  secrets_reference_scheme "$1" >/dev/null 2>&1
}

# secrets_reference_target <value> — the part after "<scheme>://".
secrets_reference_target() {
  local value="$1"
  printf '%s' "${value#*://}"
}

# secrets_provider_available <scheme>
# Returns 0 if the provider can run (tools present, creds configured). Runs the
# provider's optional `_check` hook; providers without one are assumed ready.
secrets_provider_available() {
  local scheme="$1"
  if declare -F "secrets_provider__${scheme}_check" >/dev/null 2>&1; then
    "secrets_provider__${scheme}_check"
    return $?
  fi
  return 0
}

# secrets_resolve_reference <value>
# Resolve a "<scheme>://<ref>" reference to its value on stdout. A non-reference
# value is echoed unchanged.
secrets_resolve_reference() {
  local value="$1"
  local scheme target
  if ! scheme=$(secrets_reference_scheme "$value"); then
    printf '%s' "$value"
    return 0
  fi
  target=$(secrets_reference_target "$value")
  "secrets_provider__${scheme}" "$target"
}

# ── Providers ─────────────────────────────────────────────────────────────────

# vault:// — Vaultwarden / Bitwarden item resolved via the `bw` CLI. The ref is
# the item name or id; the password field is preferred, falling back to notes.
secrets_provider__vault_check() {
  if ! command -v bw >/dev/null 2>&1; then
    fail "secrets: 'bw' (Bitwarden/Vaultwarden CLI) not found — install it to use vault:// references"
    return 1
  fi
  if [ -z "${BW_SESSION:-}" ] && [ -z "${BW_CLIENTID:-}" ]; then
    fail "secrets: no Vaultwarden session — run: export BW_SESSION=\"\$(bw unlock --raw)\" (or set BW_CLIENTID/BW_CLIENTSECRET)"
    return 1
  fi
  return 0
}

secrets_provider__vault() {
  local item="$1"
  local val
  if val=$(bw get password "$item" 2>/dev/null) && [ -n "$val" ]; then
    printf '%s' "$val"
    return 0
  fi
  if val=$(bw get notes "$item" 2>/dev/null) && [ -n "$val" ]; then
    printf '%s' "$val"
    return 0
  fi
  fail "secrets: vault item '$item' not found or empty"
  return 1
}

# exec:// — value is the stdout of a command (trailing newlines trimmed by $()).
# Note: the command runs with the caller's privileges and is visible in `ps`
# while running. Templates are user-authored, so this is execution-by-consent;
# don't hydrate a template you didn't write.
secrets_provider__exec() {
  local cmd="$1"
  local out
  if ! out=$(bash -c "$cmd"); then
    fail "secrets: exec reference failed: $cmd"
    return 1
  fi
  printf '%s' "$out"
}

# file:// — value is the contents of a file (trailing newlines trimmed by $()).
secrets_provider__file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    fail "secrets: file reference not found: $path"
    return 1
  fi
  printf '%s' "$(cat "$path")"
}
