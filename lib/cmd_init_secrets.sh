#!/usr/bin/env bash
# ==================================================
# cmd_init_secrets.sh — Generate .env from template with auto-secrets
# ==================================================
# Usage: strut <stack> init-secrets [--env <name>] [--force] [--dry-run]
#
# Reads stacks/<stack>/.env.template, detects placeholder values and
# generation hints, auto-generates secrets, and writes the output to
# the appropriate .env file. Safe to re-run — never overwrites existing
# values unless --force is passed.
# ==================================================
# Requires: lib/utils.sh sourced first

set -euo pipefail

# ── Secret generation helpers ─────────────────────────────────────────────────

# _secrets_generate_hex <bytes>
# Generate a random hex string of the specified byte length.
_secrets_generate_hex() {
  local bytes="${1:-32}"
  openssl rand -hex "$bytes" 2>/dev/null || head -c "$bytes" /dev/urandom | od -A n -t x1 | tr -d ' \n' | head -c "$((bytes * 2))"
}

# _secrets_generate_base64 <bytes>
# Generate a random base64 string of the specified byte length.
_secrets_generate_base64() {
  local bytes="${1:-32}"
  openssl rand -base64 "$bytes" 2>/dev/null | tr -d '\n' | head -c "$((bytes * 4 / 3))"
}

# _secrets_is_placeholder <value>
# Returns 0 if the value looks like a placeholder that should be replaced.
_secrets_is_placeholder() {
  local val="$1"
  # Empty values are placeholders
  [ -z "$val" ] && return 0
  # Common placeholder patterns
  case "$val" in
    change-me*|changeme*|CHANGEME*|Change-Me*) return 0 ;;
    your.*|your-*|YOUR_*|YOUR-*) return 0 ;;
    xxxx*|XXXX*|xxx*|XXX*) return 0 ;;
    ghp_xxx*) return 0 ;;
    replace-*|REPLACE_*|replace_*) return 0 ;;
    todo*|TODO*|fixme*|FIXME*) return 0 ;;
    example*|EXAMPLE*) return 0 ;;
    placeholder*|PLACEHOLDER*) return 0 ;;
  esac
  return 1
}

# _secrets_detect_type <key> <value> <comment>
# Detects what kind of secret to generate based on key name, value, and comment.
# Outputs: hex:<bytes> | base64:<bytes> | password:<length> | skip | keep
_secrets_detect_type() {
  local key="$1" value="$2" comment="${3:-}"

  # Check for explicit generation hint in comment
  # e.g. "# Generate with: openssl rand -hex 32"
  if [[ "$comment" =~ openssl[[:space:]]+rand[[:space:]]+-hex[[:space:]]+([0-9]+) ]]; then
    echo "hex:${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$comment" =~ openssl[[:space:]]+rand[[:space:]]+-base64[[:space:]]+([0-9]+) ]]; then
    echo "base64:${BASH_REMATCH[1]}"
    return
  fi

  # If value is not a placeholder, keep it as-is
  if ! _secrets_is_placeholder "$value"; then
    echo "keep"
    return
  fi

  # Auto-detect based on key name
  local key_lower
  key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')

  case "$key_lower" in
    *secret*|*jwt*)
      echo "hex:32"
      ;;
    *password*|*passwd*|*pass)
      echo "hex:16"
      ;;
    *salt*)
      echo "hex:16"
      ;;
    *key*|*token*)
      # Only auto-generate for generic keys, not API keys that need external values
      if [[ "$key_lower" == *api_key* ]] || [[ "$key_lower" == *api_secret* ]]; then
        echo "skip"
      else
        echo "hex:24"
      fi
      ;;
    *encryption*)
      echo "hex:32"
      ;;
    *)
      echo "skip"
      ;;
  esac
}

# _secrets_process_template <template_file> [existing_env_file]
# Processes a template file and outputs generated key=value lines.
# If existing_env_file is provided, preserves existing values.
# Output: one line per variable: KEY=VALUE (generated or preserved)
_secrets_process_template() {
  local template="$1"
  local existing="${2:-}"
  local force="${3:-false}"

  # Load existing values into an associative array
  declare -A existing_values=()
  if [ -n "$existing" ] && [ -f "$existing" ]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        existing_values["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
      fi
    done < "$existing"
  fi

  local prev_comment=""
  local generated_count=0
  local skipped_count=0
  local preserved_count=0

  while IFS= read -r line; do
    # Track comments (they may contain generation hints)
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      prev_comment="$line"
      echo "$line"
      continue
    fi

    # Pass through empty lines
    if [ -z "$line" ]; then
      prev_comment=""
      echo ""
      continue
    fi

    # Parse KEY=VALUE
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"

      # If value exists in the current env file and we're not forcing, preserve it
      if [ "$force" != "true" ] && [ -n "${existing_values[$key]+x}" ]; then
        local existing_val="${existing_values[$key]}"
        if [ -n "$existing_val" ] && ! _secrets_is_placeholder "$existing_val"; then
          echo "${key}=${existing_val}"
          preserved_count=$((preserved_count + 1))
          prev_comment=""
          continue
        fi
      fi

      # Detect what to generate
      local gen_type
      gen_type=$(_secrets_detect_type "$key" "$value" "$prev_comment")

      case "$gen_type" in
        hex:*)
          local bytes="${gen_type#hex:}"
          local new_val
          new_val=$(_secrets_generate_hex "$bytes")
          echo "${key}=${new_val}"
          generated_count=$((generated_count + 1))
          ;;
        base64:*)
          local bytes="${gen_type#base64:}"
          local new_val
          new_val=$(_secrets_generate_base64 "$bytes")
          echo "${key}=${new_val}"
          generated_count=$((generated_count + 1))
          ;;
        password:*)
          local length="${gen_type#password:}"
          local new_val
          new_val=$(_secrets_generate_hex "$((length / 2))")
          echo "${key}=${new_val}"
          generated_count=$((generated_count + 1))
          ;;
        keep)
          echo "${key}=${value}"
          skipped_count=$((skipped_count + 1))
          ;;
        skip)
          # Leave the placeholder — user must fill this manually
          echo "${key}=${value}"
          skipped_count=$((skipped_count + 1))
          ;;
      esac
      prev_comment=""
    else
      # Pass through anything else
      echo "$line"
      prev_comment=""
    fi
  done < "$template"

  # Output counts to stderr for the caller to pick up
  echo "GENERATED=$generated_count" >&2
  echo "SKIPPED=$skipped_count" >&2
  echo "PRESERVED=$preserved_count" >&2
}

# ── Command handler ───────────────────────────────────────────────────────────

_usage_init_secrets() {
  echo "Usage: strut <stack> init-secrets [--env <name>] [--force] [--dry-run]"
  echo ""
  echo "Generate a populated .env file from the stack's .env.template."
  echo "Auto-generates secrets for PASSWORD, SECRET, SALT, TOKEN, and KEY variables."
  echo "Respects generation hints in comments (e.g. '# openssl rand -hex 32')."
  echo ""
  echo "Options:"
  echo "  --env <name>   Target environment name (default: prod)"
  echo "  --force        Overwrite existing values (default: preserve)"
  echo "  --dry-run      Print generated env to stdout without writing"
  echo ""
  echo "Safety:"
  echo "  - Never overwrites existing non-placeholder values (unless --force)"
  echo "  - Safe to re-run — only fills in missing/placeholder values"
  echo "  - Variables that need manual input (API keys, domains) are left as-is"
  echo ""
  echo "Examples:"
  echo "  strut langfuse init-secrets --env prod"
  echo "  strut my-app init-secrets --dry-run"
  echo "  strut my-app init-secrets --env staging --force"
}

cmd_init_secrets() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_name="${CMD_ENV_NAME:-prod}"
  local dry_run="${DRY_RUN:-false}"
  local force=false

  # Parse command-specific flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=true; shift ;;
      *) shift ;;
    esac
  done

  local template="$stack_dir/.env.template"
  if [ ! -f "$template" ]; then
    fail "No .env.template found at: $template"
    return 1
  fi

  # Determine output path
  local output_file="$CLI_ROOT/.${env_name}.env"

  log "Generating secrets for stack '$stack' (env: $env_name)"
  log "Template: $template"
  [ "$force" = "true" ] && warn "Force mode: existing values will be overwritten"

  # Process template
  local result
  local counts
  counts=$(mktemp)
  result=$(_secrets_process_template "$template" "$output_file" "$force" 2>"$counts")

  local generated skipped preserved
  generated=$(grep "^GENERATED=" "$counts" | cut -d= -f2)
  skipped=$(grep "^SKIPPED=" "$counts" | cut -d= -f2)
  preserved=$(grep "^PRESERVED=" "$counts" | cut -d= -f2)
  rm -f "$counts"

  # Dry-run mode
  if [ "$dry_run" = "true" ]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Generated env contents:${NC}"
    echo "─────────────────────────────────────────"
    echo "$result"
    echo "─────────────────────────────────────────"
    echo ""
    log "Generated: ${generated:-0} secrets"
    log "Skipped: ${skipped:-0} (need manual input)"
    log "Preserved: ${preserved:-0} (existing values kept)"
    echo ""
    echo -e "${YELLOW}[DRY-RUN] No file written.${NC}"
    return 0
  fi

  # Write output
  echo "$result" > "$output_file"
  ok "Env file written: $output_file"
  echo ""
  log "Generated: ${generated:-0} secrets"
  log "Skipped: ${skipped:-0} (need manual input)"
  log "Preserved: ${preserved:-0} (existing values kept)"

  # Warn about remaining placeholders
  local remaining_placeholders=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local val="${BASH_REMATCH[2]}"
      if _secrets_is_placeholder "$val"; then
        remaining_placeholders=$((remaining_placeholders + 1))
      fi
    fi
  done <<< "$result"

  if [ "$remaining_placeholders" -gt 0 ]; then
    echo ""
    warn "$remaining_placeholders variable(s) still need manual input"
    warn "Edit $output_file to fill in: API keys, domains, external service URLs"
  fi
}
