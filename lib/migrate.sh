#!/usr/bin/env bash
# ==================================================
# lib/migrate.sh — Migration wizard for VPS takeover
# ==================================================
# Orchestrates the complete migration workflow from ad-hoc to strut

# Source helper modules
set -euo pipefail

MIGRATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/migrate" && pwd)"
source "$MIGRATE_LIB_DIR/ssh-helpers.sh"
source "$MIGRATE_LIB_DIR/github-auth.sh"
source "$MIGRATE_LIB_DIR/setup-repo.sh"

# Source phase modules
source "$MIGRATE_LIB_DIR/phase-preflight.sh"
source "$MIGRATE_LIB_DIR/phase-setup.sh"
source "$MIGRATE_LIB_DIR/phase-audit.sh"
source "$MIGRATE_LIB_DIR/phase-generate.sh"
source "$MIGRATE_LIB_DIR/phase-backup.sh"
source "$MIGRATE_LIB_DIR/phase-test.sh"
source "$MIGRATE_LIB_DIR/phase-cutover.sh"
source "$MIGRATE_LIB_DIR/phase-cleanup.sh"

# Global flag for auto-yes mode
MIGRATE_AUTO_YES=false

# Global flag for starting phase
MIGRATE_START_PHASE=1

# Helper function for yes/no prompts (accepts yes/y/no/n)
# Usage: if confirm "Continue?"; then ... fi
# Set MIGRATE_AUTO_YES=true to auto-answer yes
confirm() {
  local prompt="${1:-Continue?}"

  # Auto-yes mode
  if [ "$MIGRATE_AUTO_YES" = true ]; then
    echo "$prompt (yes/no): yes [auto]"
    return 0
  fi

  read -p "$prompt (yes/no): " -r
  # Trim whitespace from reply
  REPLY=$(echo "$REPLY" | xargs)
  [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Helper function for input prompts with default values
# Usage: response=$(prompt_with_default "Enter name" "default-value")
# Set MIGRATE_AUTO_YES=true to auto-use default
prompt_with_default() {
  local prompt="$1"
  local default="$2"

  # Auto-yes mode - use default
  if [ "$MIGRATE_AUTO_YES" = true ]; then
    echo "$prompt [$default]: $default [auto]"
    echo "$default"
    return 0
  fi

  read -p "$prompt [$default]: " -r response
  response=$(echo "$response" | xargs)  # trim
  [ -z "$response" ] && response="$default"
  echo "$response"
}

# migrate_wizard <vps_host> [vps_user] [ssh_port] [ssh_key] [--yes] [--sudo] [--start-phase N] [--stack <name>]
# Interactive wizard for complete VPS migration
migrate_wizard() {
  local vps_host="$1"
  local vps_user="${2:-ubuntu}"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"
  local arg5="${5:-}"
  local arg6="${6:-}"

  # Stack filter (empty = all stacks)
  local MIGRATE_STACK_FILTER=""

  # Parse flags from any position
  local args=("$@")
  local i=0
  for arg in "${args[@]}"; do
    if [ "$arg" = "--yes" ] || [ "$arg" = "-y" ]; then
      MIGRATE_AUTO_YES=true
    elif [ "$arg" = "--sudo" ]; then
      export VPS_SUDO=true
    elif [[ "$arg" =~ ^--start-phase=([0-9]+)$ ]]; then
      MIGRATE_START_PHASE="${BASH_REMATCH[1]}"
    elif [ "$arg" = "--start-phase" ]; then
      # Next arg should be the phase number
      local next_is_phase=false
      for a in "${args[@]}"; do
        if $next_is_phase; then
          MIGRATE_START_PHASE="$a"
          break
        fi
        [ "$a" = "--start-phase" ] && next_is_phase=true
      done
    elif [[ "$arg" =~ ^--stack=(.+)$ ]]; then
      MIGRATE_STACK_FILTER="${BASH_REMATCH[1]}"
    elif [ "$arg" = "--stack" ]; then
      # Next arg should be the stack name
      local next_is_stack=false
      for a in "${args[@]}"; do
        if $next_is_stack; then
          MIGRATE_STACK_FILTER="$a"
          break
        fi
        [ "$a" = "--stack" ] && next_is_stack=true
      done
    fi
    i=$((i + 1))
  done

  # Clean up positional args (remove flags)
  [ "$ssh_port" = "--yes" ] || [ "$ssh_port" = "-y" ] || [[ "$ssh_port" =~ ^--start-phase ]] || [[ "$ssh_port" =~ ^--stack ]] && ssh_port=""
  [ "$ssh_key" = "--yes" ] || [ "$ssh_key" = "-y" ] || [[ "$ssh_key" =~ ^--start-phase ]] || [[ "$ssh_key" =~ ^--stack ]] && ssh_key=""
  [ "$ssh_port" = "--sudo" ] && ssh_port=""
  [ "$ssh_key" = "--sudo" ] && ssh_key=""

  [ -n "$vps_host" ] || fail "Usage: migrate_wizard <vps_host> [vps_user] [ssh_port] [ssh_key] [--yes] [--sudo] [--start-phase N] [--stack <name>]"

  # Validate start phase
  if [ "$MIGRATE_START_PHASE" -lt 1 ] || [ "$MIGRATE_START_PHASE" -gt 8 ]; then
    fail "Invalid start phase: $MIGRATE_START_PHASE (must be 1-8)"
  fi

  echo ""
  echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}   strut Migration Wizard${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "This wizard will guide you through migrating an existing VPS"
  echo "to strut management."
  echo ""
  echo "Target VPS: $vps_user@$vps_host"
  [ -n "$ssh_port" ] && echo "SSH Port: $ssh_port"
  [ -n "$ssh_key" ] && echo "SSH Key: $ssh_key"
  [ "$MIGRATE_AUTO_YES" = true ] && echo "Mode: Automated (--yes)"
  [ "${VPS_SUDO:-false}" = "true" ] && echo "Docker sudo: enabled (--sudo)"
  [ -n "$MIGRATE_STACK_FILTER" ] && echo "Stack filter: $MIGRATE_STACK_FILTER"
  [ "$MIGRATE_START_PHASE" -gt 1 ] && echo "Starting from: Phase $MIGRATE_START_PHASE"
  echo ""
  if ! confirm "Continue?"; then
    log "Migration cancelled"
    return 0
  fi

  # Phase 1: Pre-flight checks
  if [ "$MIGRATE_START_PHASE" -le 1 ]; then
    migrate_phase_preflight "$vps_host" "$vps_user" "$ssh_port" "$ssh_key"
  else
    log "Skipping Phase 1 (Pre-flight) - starting from Phase $MIGRATE_START_PHASE"
  fi

  # Phase 2: Setup strut on VPS
  if [ "$MIGRATE_START_PHASE" -le 2 ]; then
    migrate_phase_setup "$vps_host" "$vps_user" "$ssh_port" "$ssh_key"
  else
    log "Skipping Phase 2 (Setup) - starting from Phase $MIGRATE_START_PHASE"
  fi

  # Phase 3: Audit existing setup
  if [ "$MIGRATE_START_PHASE" -le 3 ]; then
    migrate_phase_audit "$vps_host" "$vps_user" "$ssh_port" "$ssh_key"
  else
    log "Skipping Phase 3 (Audit) - starting from Phase $MIGRATE_START_PHASE"
    # Try to find most recent audit
    local audit_dir
    audit_dir=$(ls -td "$CLI_ROOT/audits"/*-"$vps_host" 2>/dev/null | head -1)
    if [ -n "$audit_dir" ]; then
      export MIGRATION_AUDIT_DIR="$audit_dir"
      log "Using existing audit: $audit_dir"
    else
      warn "No existing audit found for $vps_host"
      warn "You may need to run Phase 3 first"
    fi
  fi

  # Phase 4: Generate stacks
  if [ "$MIGRATE_START_PHASE" -le 4 ]; then
    migrate_phase_generate "$vps_host" "$vps_user" "$ssh_port" "$ssh_key"
  else
    log "Skipping Phase 4 (Generate) - starting from Phase $MIGRATE_START_PHASE"
    # Try to detect generated stacks
    local detected_stacks=""
    for stack_dir in "$CLI_ROOT/stacks"/*/; do
      local stack_name
      stack_name=$(basename "$stack_dir")
      [ "$stack_name" = "shared" ] && continue
      [ "$stack_name" = "my-stack" ] && continue
      if [ -f "$stack_dir/docker-compose.yml" ]; then
        if [ -n "$detected_stacks" ]; then
          detected_stacks="$detected_stacks,$stack_name"
        else
          detected_stacks="$stack_name"
        fi
      fi
    done
    if [ -n "$detected_stacks" ]; then
      # Apply --stack filter if specified
      if [ -n "$MIGRATE_STACK_FILTER" ]; then
        local filtered=""
        IFS=',' read -ra _all_stacks <<< "$detected_stacks"
        for _s in "${_all_stacks[@]}"; do
          _s=$(echo "$_s" | xargs)
          if [ "$_s" = "$MIGRATE_STACK_FILTER" ]; then
            filtered="$_s"
            break
          fi
        done
        if [ -n "$filtered" ]; then
          detected_stacks="$filtered"
          log "Filtered to stack: $filtered"
        else
          warn "Stack '$MIGRATE_STACK_FILTER' not found in detected stacks: $detected_stacks"
        fi
      fi
      export MIGRATION_STACKS="$detected_stacks"
      log "Detected stacks: $detected_stacks"
    else
      warn "No generated stacks found"
      warn "You may need to run Phase 4 first"
    fi
  fi

  # Phase 5: Pre-Cutover Backup
  if [ "$MIGRATE_START_PHASE" -le 5 ]; then
    # Apply --stack filter before backup phase
    if [ -n "$MIGRATE_STACK_FILTER" ] && [ -n "${MIGRATION_STACKS:-}" ]; then
      local filtered=""
      IFS=',' read -ra _all_stacks <<< "$MIGRATION_STACKS"
      for _s in "${_all_stacks[@]}"; do
        _s=$(echo "$_s" | xargs)
        if [ "$_s" = "$MIGRATE_STACK_FILTER" ]; then
          filtered="$_s"
          break
        fi
      done
      if [ -n "$filtered" ]; then
        export MIGRATION_STACKS="$filtered"
        log "Filtered to stack: $filtered"
      fi
    fi
    migrate_phase_backup "$vps_host" "$vps_user" "$ssh_port" "$ssh_key"
  else
    log "Skipping Phase 5 (Backup) - starting from Phase $MIGRATE_START_PHASE"
  fi

  # Phases 6-8 are interactive and require manual decisions
  # Skip them in auto-yes mode
  if [ "$MIGRATE_AUTO_YES" = true ]; then
    echo ""
    echo -e "${YELLOW}Skipping Phases 6-8 (Test/Cutover/Cleanup) in auto-yes mode${NC}"
    echo ""
    echo "To complete migration:"
    echo "  1. Review generated stacks in stacks/<stack-name>/"
    echo "  2. Review environment files: .{stack-name}-prod.env"
    echo "  3. Review pre-migration backups in backups/pre-migration-*/"
    echo "  4. Test locally: strut <stack> deploy --env <stack>-prod"
    echo "  5. Deploy to VPS: strut <stack> deploy --env <stack>-prod --remote"
    echo "  6. Run health checks: strut <stack> health --env <stack>-prod"
    echo ""
    echo "Or resume with: strut migrate $vps_host $vps_user --start-phase 6"
    [ -n "$MIGRATE_STACK_FILTER" ] && echo "  (add --stack $MIGRATE_STACK_FILTER to limit to a single stack)"
    echo ""
    return 0
  fi

  # Phase 6: Test deployment
  if [ "$MIGRATE_START_PHASE" -le 6 ]; then
    migrate_phase_test "$vps_host" "$vps_user" "$ssh_port" "$ssh_key"
  else
    log "Skipping Phase 6 (Test) - starting from Phase $MIGRATE_START_PHASE"
  fi

  # Phase 7: Cutover
  if [ "$MIGRATE_START_PHASE" -le 7 ]; then
    migrate_phase_cutover "$vps_host" "$vps_user" "$ssh_port" "$ssh_key"
  else
    log "Skipping Phase 7 (Cutover) - starting from Phase $MIGRATE_START_PHASE"
  fi

  # Phase 8: Cleanup
  if [ "$MIGRATE_START_PHASE" -le 8 ]; then
    migrate_phase_cleanup "$vps_host" "$vps_user" "$ssh_port" "$ssh_key"
  fi

  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}   Migration Complete!${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "Your VPS is now managed by strut."
  echo ""
  echo "Next steps:"
  echo "  - Monitor: strut <stack> health --env prod"
  echo "  - View logs: strut <stack> logs --follow --env prod"
  echo "  - Set up backups: strut <stack> backup all --env prod"
  echo ""
}

# migrate_status
# Show status of ongoing migration
migrate_status() {
  echo ""
  echo -e "${BLUE}Migration Status${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Check for recent audits
  if [ -d "$CLI_ROOT/audits" ]; then
    local audit_count
    audit_count=$(ls -1 "$CLI_ROOT/audits" | wc -l)
    echo "Audits: $audit_count"

    if [ "$audit_count" -gt 0 ]; then
      echo "Recent audits:"
      ls -t "$CLI_ROOT/audits" | head -3 | sed 's/^/  - /'
    fi
  fi

  echo ""

  # Check for generated stacks
  if [ -d "$CLI_ROOT/stacks" ]; then
    echo "Generated stacks:"
    for stack_dir in "$CLI_ROOT/stacks"/*/; do
      local name
      name=$(basename "$stack_dir")
      [ "$name" = "shared" ] && continue

      if [ -f "$stack_dir/docker-compose.yml" ]; then
        echo "  - $name"

        # Check if env file exists
        if [ -f "$CLI_ROOT/.$name-prod.env" ]; then
          echo "    ✓ Env file exists"
        else
          echo "    ✗ Env file missing"
        fi
      fi
    done
  fi

  echo ""
}
