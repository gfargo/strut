#!/usr/bin/env bash
# ==================================================
# cmd_validate.sh — Config validation command handler
# ==================================================
# Validates strut.conf, services.conf, volume.conf, backup.conf,
# and required_vars for a stack.
#
# Provides:
#   cmd_validate (reads CMD_* context variables)
#   _validate_strut_conf
#   _validate_services_conf <stack_dir>
#   _validate_volume_conf <stack_dir>
#   _validate_backup_conf <stack_dir>
#   _validate_required_vars <stack_dir> <env_file>

set -euo pipefail

# ── Counters ──────────────────────────────────────────────────────────────────
_VALIDATE_ERRORS=0
_VALIDATE_WARNINGS=0

_val_error() {
  local file="$1" msg="$2"
  echo -e "  ${RED}✗${NC} $file: $msg"
  _VALIDATE_ERRORS=$((_VALIDATE_ERRORS + 1))
}

_val_warn() {
  local file="$1" msg="$2"
  echo -e "  ${YELLOW}⚠${NC} $file: $msg"
  _VALIDATE_WARNINGS=$((_VALIDATE_WARNINGS + 1))
}

_val_ok() {
  local file="$1" msg="$2"
  echo -e "  ${GREEN}✓${NC} $file: $msg"
}

_usage_validate() {
  echo ""
  echo "Usage: strut <stack> validate [--env <name>]"
  echo ""
  echo "Validate all config files for a stack."
  echo "Checks strut.conf, services.conf, volume.conf, backup.conf,"
  echo "and required_vars against expected schemas."
  echo ""
  echo "Exit code 0 if valid, 1 if errors found."
  echo ""
  echo "Examples:"
  echo "  strut my-stack validate"
  echo "  strut my-stack validate --env prod"
  echo ""
}

# ── Validation helpers ────────────────────────────────────────────────────────

# _is_valid_port <value>
# Returns 0 if value is a numeric port in range 1-65535
_is_valid_port() {
  local val="$1"
  [[ "$val" =~ ^[0-9]+$ ]] || return 1
  [ "$val" -ge 1 ] && [ "$val" -le 65535 ]
}

# _is_valid_boolean <value>
# Returns 0 if value is "true" or "false"
_is_valid_boolean() {
  local val="$1"
  [[ "$val" == "true" || "$val" == "false" ]]
}

# ── strut.conf validation ─────────────────────────────────────────────────────

_validate_strut_conf() {
  local conf_file="${PROJECT_ROOT:-$CLI_ROOT}/strut.conf"

  if [ ! -f "$conf_file" ]; then
    _val_warn "strut.conf" "not found (using defaults)"
    return
  fi

  # Source it to get values
  local _registry_type="" _reverse_proxy="" _default_branch=""
  while IFS='=' read -r key val; do
    # Skip comments and empty lines
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$key" | xargs)
    val=$(echo "$val" | xargs)
    case "$key" in
      REGISTRY_TYPE)   _registry_type="$val" ;;
      REVERSE_PROXY)   _reverse_proxy="$val" ;;
      DEFAULT_BRANCH)  _default_branch="$val" ;;
    esac
  done < "$conf_file"

  local valid=true

  if [ -n "$_registry_type" ]; then
    case "$_registry_type" in
      ghcr|dockerhub|ecr|none) ;;
      *) _val_error "strut.conf" "REGISTRY_TYPE='$_registry_type' (valid: ghcr, dockerhub, ecr, none)"; valid=false ;;
    esac
  fi

  if [ -n "$_reverse_proxy" ]; then
    case "$_reverse_proxy" in
      nginx|caddy) ;;
      *) _val_error "strut.conf" "REVERSE_PROXY='$_reverse_proxy' (valid: nginx, caddy)"; valid=false ;;
    esac
  fi

  if [ -n "$_default_branch" ]; then
    if [[ "$_default_branch" =~ [[:space:]] ]]; then
      _val_error "strut.conf" "DEFAULT_BRANCH='$_default_branch' contains spaces"
      valid=false
    fi
  fi

  $valid && _val_ok "strut.conf" "valid"
}

# ── services.conf validation ──────────────────────────────────────────────────

_validate_services_conf() {
  local stack_dir="$1"
  local conf_file="$stack_dir/services.conf"

  if [ ! -f "$conf_file" ]; then
    _val_warn "services.conf" "not found (health checks will use defaults)"
    return
  fi

  local valid=true
  local service_count=0
  local db_count=0

  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$key" | xargs)
    val=$(echo "$val" | xargs)

    # Port validation
    if [[ "$key" == *_PORT ]]; then
      service_count=$((service_count + 1))
      if ! _is_valid_port "$val"; then
        _val_error "services.conf" "$key='$val' (must be numeric, 1-65535)"
        valid=false
      fi
    fi

    # Health path validation
    if [[ "$key" == HEALTH_PATH_* || "$key" == *_HEALTH_PATH ]]; then
      if [[ "$val" != /* ]]; then
        _val_warn "services.conf" "$key='$val' (should start with /)"
      fi
    fi

    # DB flag validation
    if [[ "$key" == DB_* ]]; then
      db_count=$((db_count + 1))
      if ! _is_valid_boolean "$val"; then
        _val_error "services.conf" "$key='$val' (must be true or false)"
        valid=false
      fi
    fi
  done < "$conf_file"

  $valid && _val_ok "services.conf" "valid ($service_count services, $db_count databases)"
}

# ── volume.conf validation ────────────────────────────────────────────────────

_validate_volume_conf() {
  local stack_dir="$1"
  local conf_file="$stack_dir/volume.conf"

  if [ ! -f "$conf_file" ]; then
    return  # volume.conf is optional, no warning needed
  fi

  local valid=true

  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$key" | xargs)
    val=$(echo "$val" | xargs)

    # Path validation — check *_DATA_PATH and *_PATH keys
    if [[ "$key" == *_DATA_PATH || "$key" == *_PATH ]]; then
      # Expand variables in val
      local expanded
      expanded=$(eval echo "$val" 2>/dev/null || echo "$val")
      if [[ "$expanded" != /* ]]; then
        _val_warn "volume.conf" "$key='$val' (should be an absolute path)"
      fi
    fi

    # VOLUME_OWNERS format: path:uid:gid
    if [[ "$key" == "VOLUME_OWNERS" ]]; then
      IFS=' ' read -ra entries <<< "$val"
      for entry in "${entries[@]}"; do
        if [[ ! "$entry" =~ ^[^:]+:[0-9]+:[0-9]+$ ]]; then
          _val_error "volume.conf" "VOLUME_OWNERS entry '$entry' (expected path:uid:gid)"
          valid=false
        fi
      done
    fi
  done < "$conf_file"

  $valid && _val_ok "volume.conf" "valid"
}

# ── backup.conf validation ────────────────────────────────────────────────────

_validate_backup_conf() {
  local stack_dir="$1"
  local conf_file="$stack_dir/backup.conf"

  if [ ! -f "$conf_file" ]; then
    return  # backup.conf is optional
  fi

  local valid=true

  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$key" | xargs)
    val=$(echo "$val" | xargs | tr -d '"')

    # Boolean flags
    if [[ "$key" == BACKUP_POSTGRES || "$key" == BACKUP_NEO4J || "$key" == BACKUP_MYSQL || "$key" == BACKUP_SQLITE ]]; then
      if ! _is_valid_boolean "$val"; then
        _val_error "backup.conf" "$key='$val' (must be true or false)"
        valid=false
      fi
    fi

    # Numeric values
    if [[ "$key" == BACKUP_RETAIN_DAYS || "$key" == BACKUP_RETAIN_COUNT ]]; then
      if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        _val_error "backup.conf" "$key='$val' (must be numeric)"
        valid=false
      fi
    fi

    # Cron schedule validation (5 fields)
    if [[ "$key" == BACKUP_SCHEDULE_* ]]; then
      local field_count
      field_count=$(echo "$val" | awk '{print NF}')
      if [ "$field_count" -ne 5 ]; then
        _val_error "backup.conf" "$key='$val' (must be a 5-field cron expression)"
        valid=false
      fi
    fi
  done < "$conf_file"

  $valid && _val_ok "backup.conf" "valid"
}

# ── required_vars validation ──────────────────────────────────────────────────

_validate_required_vars() {
  local stack_dir="$1"
  local env_file="$2"
  local vars_file="$stack_dir/required_vars"

  if [ ! -f "$vars_file" ]; then
    return  # required_vars is optional
  fi

  if [ ! -f "$env_file" ]; then
    _val_warn "required_vars" "env file not found: $env_file (skipping validation)"
    return
  fi

  local valid=true
  local missing=()

  # Source env file to get values
  set -a
  source "$env_file" 2>/dev/null || true
  set +a

  while IFS= read -r var || [ -n "$var" ]; do
    var=$(echo "$var" | xargs)
    [ -z "$var" ] && continue
    [[ "$var" =~ ^# ]] && continue

    local val
    val=$(eval echo "\${${var}:-}" 2>/dev/null || echo "")
    if [ -z "$val" ]; then
      missing+=("$var")
      valid=false
    fi
  done < "$vars_file"

  if [ ${#missing[@]} -gt 0 ]; then
    for var in "${missing[@]}"; do
      _val_error "required_vars" "missing or empty: $var (in $(basename "$env_file"))"
    done
  else
    local var_count
    var_count=$(grep -cve '^\s*$' "$vars_file" 2>/dev/null || echo 0)
    _val_ok "required_vars" "all $var_count required vars present"
  fi
}

# ── Main command ──────────────────────────────────────────────────────────────

cmd_validate() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"

  _VALIDATE_ERRORS=0
  _VALIDATE_WARNINGS=0

  echo ""
  echo -e "${BLUE}Validating configuration for stack: $stack${NC}"
  echo ""

  _validate_strut_conf
  _validate_services_conf "$stack_dir"
  _validate_volume_conf "$stack_dir"
  _validate_backup_conf "$stack_dir"
  _validate_required_vars "$stack_dir" "$env_file"

  echo ""
  if [ $_VALIDATE_ERRORS -gt 0 ]; then
    echo -e "${RED}$_VALIDATE_ERRORS error(s)${NC}, $_VALIDATE_WARNINGS warning(s)"
    return 1
  elif [ $_VALIDATE_WARNINGS -gt 0 ]; then
    echo -e "${GREEN}Valid${NC} with $_VALIDATE_WARNINGS warning(s)"
    return 0
  else
    echo -e "${GREEN}All config files valid${NC}"
    return 0
  fi
}
