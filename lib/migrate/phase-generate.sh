#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-generate.sh — Phase 4: Generate stacks from audit data
# ==================================================

# migrate_phase_generate <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 4: Generate stacks from audit data
set -euo pipefail

migrate_phase_generate() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${BLUE}Phase 4: Generate Stack Configurations${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local audit_dir="${MIGRATION_AUDIT_DIR:-}"
  if [ -z "$audit_dir" ]; then
    audit_dir=$(ls -td "$CLI_ROOT/audits"/*-"$vps_host" 2>/dev/null | head -1)
  fi

  [ -n "$audit_dir" ] || fail "No audit found. Run audit phase first."

  # ── Parse compose projects from audit data ────────────────────────────────
  # Build project list from container labels
  local projects_file="$audit_dir/.phase4-projects.txt"
  : >"$projects_file"

  if [ -s "$audit_dir/containers.jsonl" ]; then
    while IFS= read -r line; do
      local name labels project service image ports cid
      name=$(echo "$line" | jq -r '.Names // ""' 2>/dev/null)
      labels=$(echo "$line" | jq -r '.Labels // ""' 2>/dev/null)
      image=$(echo "$line" | jq -r '.Image // ""' 2>/dev/null)
      ports=$(echo "$line" | jq -r '.Ports // ""' 2>/dev/null)
      cid=$(echo "$line" | jq -r '.ID // ""' 2>/dev/null)

      project=""
      if echo "$labels" | grep -q "com.docker.compose.project="; then
        project=$(echo "$labels" | tr ',' '\n' | grep "com.docker.compose.project=" | head -1 | cut -d'=' -f2)
      fi
      [ -z "$project" ] && project=$(echo "$name" | cut -d'-' -f1 | cut -d'_' -f1)

      service=""
      if echo "$labels" | grep -q "com.docker.compose.service="; then
        service=$(echo "$labels" | tr ',' '\n' | grep "com.docker.compose.service=" | head -1 | cut -d'=' -f2)
      fi
      [ -z "$service" ] && service="$name"

      # project|service|name|image|ports|cid
      echo "${project}|${service}|${name}|${image}|${ports}|${cid}" >>"$projects_file"
    done <"$audit_dir/containers.jsonl"
  fi

  # Get unique projects
  local projects=()
  while IFS= read -r proj; do
    [ -z "$proj" ] && continue
    projects+=("$proj")
  done < <(cut -d'|' -f1 "$projects_file" | sort -u)

  if [ ${#projects[@]} -eq 0 ]; then
    warn "No container groups found in audit data."
    rm -f "$projects_file"
    return 0
  fi

  # ── Show discovered projects ──────────────────────────────────────────────
  echo "Discovered ${#projects[@]} container group(s) from audit:"
  echo ""

  local idx=0
  for project in "${projects[@]}"; do
    idx=$((idx + 1))
    local container_count
    container_count=$(grep "^${project}|" "$projects_file" | wc -l | tr -d ' ')

    echo "  ${idx}. ${project} (${container_count} containers)"

    # Show containers in this project
    while IFS='|' read -r _proj svc cname cimage _cports _ccid; do
      echo "     └─ ${svc} (${cname}) → ${cimage}"
    done < <(grep "^${project}|" "$projects_file")
    echo ""
  done

  # ── Let user select which projects to generate ────────────────────────────
  echo "Which groups do you want to generate as strut stacks?"
  echo "Enter numbers separated by commas, or 'all' for everything."
  echo ""

  local selection
  if [ "$MIGRATE_AUTO_YES" = true ]; then
    selection="all"
    echo "Selection [all]: all [auto]"
  else
    read -p "Selection [all]: " -r selection
    [ -z "$selection" ] && selection="all"
  fi

  local selected_projects=()
  if [ "$selection" = "all" ]; then
    selected_projects=("${projects[@]}")
  else
    IFS=',' read -ra NUMS <<<"$selection"
    for num in "${NUMS[@]}"; do
      num=$(echo "$num" | xargs | tr -d ' ') # trim
      if [ "$num" -ge 1 ] 2>/dev/null && [ "$num" -le "${#projects[@]}" ] 2>/dev/null; then
        local pidx=$((num - 1))
        selected_projects+=("${projects[$pidx]}")
      else
        warn "Invalid selection: $num (skipping)"
      fi
    done
  fi

  if [ ${#selected_projects[@]} -eq 0 ]; then
    warn "No projects selected. Skipping generation."
    rm -f "$projects_file"
    return 0
  fi

  # ── Let user name each stack ──────────────────────────────────────────────
  echo ""
  echo "Name your stacks. Press Enter to accept the suggested name."
  echo ""

  # Arrays to track: project -> stack_name mapping
  local stack_names=()
  local stack_projects=()

  for project in "${selected_projects[@]}"; do
    local suggested_name="$project"
    local custom_name
    if [ "$MIGRATE_AUTO_YES" = true ]; then
      custom_name="$suggested_name"
      echo "Stack name for '$project' [$suggested_name]: $suggested_name [auto]"
    else
      read -p "Stack name for '$project' [$suggested_name]: " -r custom_name
      custom_name=$(echo "$custom_name" | xargs) # trim
      [ -z "$custom_name" ] && custom_name="$suggested_name"
    fi

    stack_names+=("$custom_name")
    stack_projects+=("$project")
  done

  echo ""
  echo "Will generate:"
  local sidx=0
  for sname in "${stack_names[@]}"; do
    echo "  - ${sname} (from project: ${stack_projects[$sidx]})"
    sidx=$((sidx + 1))
  done
  echo ""

  if ! confirm "Proceed?"; then
    warn "Generation cancelled."
    rm -f "$projects_file"
    return 0
  fi

  # ── Generate each stack ───────────────────────────────────────────────────
  local generated_stacks=""
  local project_mapping="" # Track stack_name:original_project mapping
  sidx=0
  for sname in "${stack_names[@]}"; do
    local project="${stack_projects[$sidx]}"
    sidx=$((sidx + 1))

    echo ""
    log "Generating stack: $sname (from project: $project)"

    # Call the improved audit_generate_stack with compose_project parameter
    audit_generate_stack "$sname" "$audit_dir" "$project"

    # ── Pull env values from VPS ──────────────────────────────────────────
    echo ""
    if confirm "Pull environment values from VPS for $sname?"; then
      log "Pulling environment values from running containers..."

      local env_file="$CLI_ROOT/.${sname}-prod.env"

      # Copy the template as starting point
      if [ -f "$CLI_ROOT/stacks/$sname/.env.template" ]; then
        cp "$CLI_ROOT/stacks/$sname/.env.template" "$env_file"
      fi

      # Build SSH command
      local ssh_opts
      ssh_opts=$(build_ssh_opts -p "$ssh_port" -k "$ssh_key")

      # For each container in this project, pull actual env values
      local pulled_count=0

      while IFS='|' read -r _proj _svc cname _cimage _cports _ccid; do
        log "  Pulling env from container: $cname"

        # Get actual env key=value pairs from running container
        local container_env
        container_env=$(ssh $ssh_opts "$vps_user@$vps_host" "$(vps_sudo_prefix)docker exec $cname env 2>/dev/null" 2>/dev/null || echo "")

        if [ -n "$container_env" ]; then
          # Write filtered env to a temp file to avoid subshell issues
          local filtered_env_file="$CLI_ROOT/.pull-filtered-$$"
          echo "$container_env" | grep -v -E '^(PATH=|LANG=|GPG_KEY=|GOSU_VERSION=|PYTHON_VERSION=|PYTHON_SHA256=|NODE_VERSION=|YARN_VERSION=|PG_MAJOR=|PG_VERSION=|PGDATA=|HOSTNAME=|HOME=|TERM=|SHLVL=|PWD=)' >"$filtered_env_file" 2>/dev/null || true

          # Process each env line (using file redirect, not pipe, to stay in main shell)
          while IFS= read -r env_line; do
            [ -z "$env_line" ] && continue
            local key val
            key=$(echo "$env_line" | cut -d'=' -f1)
            val=$(echo "$env_line" | cut -d'=' -f2-)

            # Update the env file: replace the empty key= with the actual value
            if grep -q "^${key}=$" "$env_file" 2>/dev/null; then
              # Use awk for safe replacement (handles special chars in values)
              awk -v k="$key" -v line="$env_line" '{ if ($0 == k"=") print line; else print $0 }' "$env_file" >"$env_file.tmp" && mv "$env_file.tmp" "$env_file"
              pulled_count=$((pulled_count + 1))
            elif ! grep -q "^${key}=" "$env_file" 2>/dev/null; then
              # Key not in template, add it
              echo "$env_line" >>"$env_file"
              pulled_count=$((pulled_count + 1))
            fi
          done <"$filtered_env_file"

          rm -f "$filtered_env_file"
        else
          warn "  Could not pull env from $cname (container may not support exec)"
        fi
      done < <(grep "^${project}|" "$projects_file")

      if [ "$pulled_count" -gt 0 ]; then
        ok "Pulled $pulled_count environment values to: .${sname}-prod.env"
      else
        warn "No values pulled. You may need to fill in .${sname}-prod.env manually."
      fi
    else
      # Just copy template
      if [ -f "$CLI_ROOT/stacks/$sname/.env.template" ]; then
        cp "$CLI_ROOT/stacks/$sname/.env.template" "$CLI_ROOT/.${sname}-prod.env"
        log "Copied template to .${sname}-prod.env (fill in values manually)"
      fi
    fi

    # Track generated stacks
    if [ -n "$generated_stacks" ]; then
      generated_stacks="$generated_stacks,$sname"
      project_mapping="$project_mapping,$sname:$project"
    else
      generated_stacks="$sname"
      project_mapping="$sname:$project"
    fi
  done

  rm -f "$projects_file"

  ok "Stack generation complete"
  echo ""
  echo "Generated stacks:"
  IFS=',' read -ra STACKS <<<"$generated_stacks"
  for stack in "${STACKS[@]}"; do
    stack=$(echo "$stack" | xargs)
    echo "  - $stack"
    echo "    Config: stacks/$stack/docker-compose.yml"
    if [ -f "$CLI_ROOT/.$stack-prod.env" ]; then
      local filled_count
      filled_count=$(grep -v '^#' "$CLI_ROOT/.$stack-prod.env" 2>/dev/null | grep -v '^$' | grep -v '=$' | wc -l | tr -d ' ')
      echo "    Env: .$stack-prod.env ($filled_count values filled)"
    else
      echo "    Env: .$stack-prod.env (not created)"
    fi
  done
  echo ""

  if ! confirm "Continue to testing?"; then
    log "Migration paused. Review generated stacks and run wizard again to continue."
    exit 0
  fi

  # Store stack names for next phases
  export MIGRATION_STACKS="${generated_stacks}"
  export MIGRATION_PROJECT_MAPPING="${project_mapping}"
}
