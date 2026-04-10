#!/usr/bin/env bash
# ==================================================
# lib/migrate/phase-test.sh — Phase 6: Test deployment
# ==================================================

# migrate_phase_test <vps_host> <vps_user> <ssh_port> <ssh_key>
# Phase 6: Test deployment
set -euo pipefail

migrate_phase_test() {
  local vps_host="$1"
  local vps_user="$2"
  local ssh_port="${3:-}"
  local ssh_key="${4:-}"

  echo ""
  echo -e "${BLUE}Phase 6: Test Deployment${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local stack_names="${MIGRATION_STACKS:-}"
  if [ -z "$stack_names" ]; then
    warn "No stacks to test. Skipping test phase."
    return 0
  fi

  # Get project mapping (stack_name:original_project)
  local project_mapping="${MIGRATION_PROJECT_MAPPING:-}"

  IFS=',' read -ra STACKS <<<"$stack_names"

  for stack in "${STACKS[@]}"; do
    stack=$(echo "$stack" | xargs)

    # Get original project name for this stack
    local original_project="$stack"
    if [ -n "$project_mapping" ]; then
      for mapping in ${project_mapping//,/ }; do
        local map_stack="${mapping%%:*}"
        local map_project="${mapping##*:}"
        if [ "$map_stack" = "$stack" ]; then
          original_project="$map_project"
          break
        fi
      done
    fi

    echo ""
    echo "Testing stack: $stack"
    if [ "$original_project" != "$stack" ]; then
      echo "(original project: $original_project)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check if env file exists
    if [ ! -f "$CLI_ROOT/.$stack-prod.env" ]; then
      warn "Env file not found: .$stack-prod.env"
      if confirm "Create env file now?"; then
        cp "stacks/$stack/.env.template" "$CLI_ROOT/.$stack-prod.env"
        warn "Please edit .$stack-prod.env and fill in secrets"
        read -p "Press Enter when ready..."
      else
        warn "Skipping $stack - no env file"
        continue
      fi
    fi

    # Ask about deployment location
    echo ""
    echo "Where to test deploy?"
    echo "  1. Locally (on this machine)"
    echo "  2. On VPS (parallel to existing setup)"
    echo "  3. Skip testing for this stack"
    echo ""
    read -p "Choice (1/2/3): " -r choice

    case "$choice" in
      1)
        log "Testing local deployment..."

        local compose_file="$CLI_ROOT/stacks/$stack/docker-compose.yml"
        local local_compose="$CLI_ROOT/stacks/$stack/docker-compose.local.yml"
        local env_file="$CLI_ROOT/.$stack-prod.env"

        if [ ! -f "$compose_file" ]; then
          fail "Compose file not found: $compose_file"
        fi

        # If a local compose already exists, prefer it for port scanning and deployment
        local scan_file="$compose_file"
        if [ -f "$local_compose" ]; then
          scan_file="$local_compose"
          log "Found existing local compose: $local_compose"
        fi

        # ── Detect and resolve port conflicts ────────────────────────────────
        log "Checking for port conflicts..."
        local ports_in_use=()
        local conflicting_ports=()

        # Extract host ports from compose file
        # Handles: "3000:3000", "0.0.0.0:3000:3000", "8443:443", "10000:10000/udp"
        local compose_ports
        compose_ports=$(grep -E '^\s+- "' "$scan_file" | sed -E 's/.*[:"](([0-9]+\.){3}[0-9]+:)?([0-9]+):.*/\3/' | sort -u || true)

        for port in $compose_ports; do
          if lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
            ports_in_use+=("$port")
            conflicting_ports+=("$port")
          fi
        done

        if [ ${#conflicting_ports[@]} -gt 0 ]; then
          warn "Port conflicts detected:"
          for port in "${conflicting_ports[@]}"; do
            local process
            process=$(lsof -Pi :"$port" -sTCP:LISTEN | tail -1 | awk '{print $1 " (PID " $2 ")"}')
            echo "  - Port $port: $process"
          done
          echo ""

          if confirm "Create local compose variant with adjusted ports?"; then
            # Use existing local compose as base, or copy from production
            if [ -f "$local_compose" ]; then
              compose_file="$local_compose"
            else
              cp "$compose_file" "$local_compose"
              compose_file="$local_compose"
            fi

            # Adjust conflicting ports (add 1000 to each)
            for port in "${conflicting_ports[@]}"; do
              local new_port=$((port + 1000))
              log "  Remapping port $port → $new_port"

              # Replace host port in mappings — handles all formats:
              #   "443:443"  "0.0.0.0:443:443"  "8080:80"  "10000:10000/udp"
              # The ([": ]) prefix ensures we match the host port, not a substring
              sed -i.bak -E "s/([\":[:space:]])${port}:([0-9])/\1${new_port}:\2/" "$local_compose"
            done

            rm -f "$local_compose.bak"
            ok "Updated local compose: $local_compose"

            # Show new port mappings
            echo ""
            echo "Local port mappings:"
            grep -E '^\s+- "' "$compose_file" | grep -E '[0-9]+:[0-9]+' | sed 's/^/  /' || true
            echo ""
          else
            # Use whatever we have (local or production) as-is
            [ -f "$local_compose" ] && compose_file="$local_compose"
            warn "Proceeding with current ports (may fail)"
          fi
        else
          ok "No port conflicts detected"
          # Still prefer local compose for deployment if it exists
          [ -f "$local_compose" ] && compose_file="$local_compose"
        fi

        echo ""
        # ── Restore backups if available ──────────────────────────────────────
        log "Searching for backup directory..."

        # Check if backups directory exists
        if [ ! -d "$CLI_ROOT/backups" ]; then
          log "No backups directory found at $CLI_ROOT/backups"
          log "Skipping backup restoration, starting fresh..."
          ln -sf "$env_file" "$CLI_ROOT/stacks/$stack/.env"
          log "Starting stack with docker compose..."
          docker compose --project-name "$stack-test" -f "$compose_file" up -d
        else
          local backup_dir=""

          # First try with original project name (most reliable)
          log "Looking for backup: pre-migration-$original_project-*"
          backup_dir=$(ls -td "$CLI_ROOT/backups/pre-migration-$original_project"-* 2>/dev/null | head -1 || true)

          # If not found and stack name differs from original, try stack name
          if [ -z "$backup_dir" ] && [ "$stack" != "$original_project" ]; then
            log "No backup found for '$original_project', trying stack name '$stack'..."
            backup_dir=$(ls -td "$CLI_ROOT/backups/pre-migration-$stack"-* 2>/dev/null | head -1 || true)
          fi

          # If still not found, try base name extraction (e.g., "twenty" from "twenty-mcp")
          if [ -z "$backup_dir" ]; then
            log "No backup found, searching for similar backups..."
            local base_name="${stack%%-*}"
            if [ "$base_name" != "$stack" ]; then
              backup_dir=$(ls -td "$CLI_ROOT/backups/pre-migration-$base_name"-* 2>/dev/null | head -1 || true)

              if [ -n "$backup_dir" ]; then
                log "Found backup with base name '$base_name': $backup_dir"
              fi
            fi
          fi

          # If still nothing, offer to select manually
          if [ -z "$backup_dir" ]; then
            log "No automatic backup match found"
            local available_backups
            available_backups=$(ls -td "$CLI_ROOT/backups/pre-migration-"* 2>/dev/null || true)

            if [ -n "$available_backups" ]; then
              echo ""
              echo "Available backups:"
              local idx=0
              local backup_array=()
              while IFS= read -r bdir; do
                idx=$((idx + 1))
                backup_array+=("$bdir")
                echo "  $idx. $(basename "$bdir")"
              done <<<"$available_backups"
              echo "  0. Skip backup restoration"
              echo ""

              read -p "Select backup to restore (0-$idx): " -r backup_choice
              if [ "$backup_choice" -ge 1 ] 2>/dev/null && [ "$backup_choice" -le "$idx" ] 2>/dev/null; then
                backup_dir="${backup_array[$((backup_choice - 1))]}"
                log "Selected backup: $backup_dir"
              else
                log "Skipping backup restoration"
              fi
            fi
          fi

          if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
            echo ""
            log "Found pre-migration backup: $backup_dir"

            if confirm "Restore backup data for local testing?"; then
              log "Restoring backup data..."

              # Create .env symlink for docker compose
              ln -sf "$env_file" "$CLI_ROOT/stacks/$stack/.env"

              # Start containers first (needed for restore)
              log "Starting containers..."
              docker compose --project-name "$stack-test" -f "$compose_file" up -d

              # Wait for containers to be ready
              log "Waiting for containers to initialize..."
              sleep 15

              # Restore PostgreSQL if backup exists
              if [ -f "$backup_dir/postgres-pre-migration.sql" ]; then
                log "Restoring PostgreSQL backup..."

                # Find postgres container
                local pg_container
                pg_container=$(docker compose --project-name "$stack-test" -f "$compose_file" ps -q postgres 2>/dev/null \
                  || docker compose --project-name "$stack-test" -f "$compose_file" ps -q db 2>/dev/null \
                  || docker ps --filter "name=$stack-test" --format "{{.Names}}" | grep -i postgres | head -1)

                if [ -n "$pg_container" ]; then
                  # Wait for postgres to be ready
                  log "Waiting for PostgreSQL to be ready..."
                  for i in {1..30}; do
                    if docker exec "$pg_container" pg_isready -U postgres >/dev/null 2>&1; then
                      break
                    fi
                    sleep 1
                  done

                  # Restore backup
                  docker exec -i "$pg_container" psql -U postgres <"$backup_dir/postgres-pre-migration.sql"
                  ok "PostgreSQL backup restored"
                else
                  warn "PostgreSQL container not found, skipping restore"
                fi
              fi

              # Restore Neo4j if backup exists
              if [ -f "$backup_dir/neo4j-pre-migration.dump" ]; then
                log "Restoring Neo4j backup..."

                # Find neo4j container
                local neo4j_container
                neo4j_container=$(docker compose --project-name "$stack-test" -f "$compose_file" ps -q neo4j 2>/dev/null \
                  || docker ps --filter "name=$stack-test" --format "{{.Names}}" | grep -i neo4j | head -1)

                if [ -n "$neo4j_container" ]; then
                  # Copy backup into container
                  docker cp "$backup_dir/neo4j-pre-migration.dump" "$neo4j_container:/tmp/restore.dump"

                  # Stop neo4j, restore, restart
                  docker stop "$neo4j_container"
                  docker exec "$neo4j_container" neo4j-admin database load neo4j --from-path=/tmp/restore.dump --overwrite-destination 2>/dev/null \
                    || warn "Neo4j restore may have failed (check logs)"
                  docker start "$neo4j_container"
                  ok "Neo4j backup restored"
                else
                  warn "Neo4j container not found, skipping restore"
                fi
              fi

              ok "Backup restoration complete"
            else
              log "Skipping backup restoration"

              # Create .env symlink and start normally
              ln -sf "$env_file" "$CLI_ROOT/stacks/$stack/.env"
              log "Starting stack with docker compose..."
              docker compose --project-name "$stack-test" -f "$compose_file" up -d
            fi
          else
            # No backup, start normally
            log "No backup found for '$stack', starting fresh..."
            log "To create a backup, run Phase 5 first"
            ln -sf "$env_file" "$CLI_ROOT/stacks/$stack/.env"
            log "Starting stack with docker compose..."
            docker compose --project-name "$stack-test" -f "$compose_file" up -d
          fi
        fi # Close the backups directory check

        # ── Health check ──────────────────────────────────────────────────────
        log "Waiting for services to stabilize..."
        sleep 10

        log "Checking container status..."
        docker compose --project-name "$stack-test" -f "$compose_file" ps

        # Check for unhealthy containers
        local unhealthy
        unhealthy=$(docker compose --project-name "$stack-test" -f "$compose_file" ps --format json 2>/dev/null \
          | jq -r 'select(.Health == "unhealthy") | .Name' 2>/dev/null || echo "")

        if [ -n "$unhealthy" ]; then
          warn "Unhealthy containers detected:"
          echo "$unhealthy" | sed 's/^/  - /'
          echo ""
          echo "View logs with:"
          for container in $unhealthy; do
            echo "  docker logs $container"
          done
        fi

        echo ""
        log "Test deployment complete. Review the output above."
        echo ""
        echo "Useful commands:"
        echo "  View logs: docker compose --project-name $stack-test -f $compose_file logs --follow"
        echo "  Check status: docker compose --project-name $stack-test -f $compose_file ps"
        echo "  Stop: docker compose --project-name $stack-test -f $compose_file down"

        # Show port mappings if adjusted
        if [ ${#conflicting_ports[@]} -gt 0 ]; then
          echo ""
          echo "Access services at adjusted ports:"
          for port in "${conflicting_ports[@]}"; do
            local new_port=$((port + 1000))
            echo "  http://localhost:$new_port (was $port)"
          done
        fi
        ;;
      2)
        log "Testing VPS deployment..."

        # Build SCP command
        local scp_cmd
        scp_cmd=$(build_scp_cmd "$vps_user" "$vps_host" "$ssh_port" "$ssh_key")

        # Copy stack files to VPS
        log "Copying stack files to VPS..."
        ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
          "mkdir -p /home/$vps_user/strut/stacks/$stack"

        $scp_cmd "$CLI_ROOT/stacks/$stack/docker-compose.yml" \
          "$vps_user@$vps_host:/home/$vps_user/strut/stacks/$stack/docker-compose.yml"

        $scp_cmd "$CLI_ROOT/.$stack-prod.env" \
          "$vps_user@$vps_host:/home/$vps_user/strut/.$stack-prod.env"

        # Deploy on VPS with simple docker compose
        log "Deploying on VPS..."
        ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
          "cd /home/$vps_user/strut && docker compose --env-file .$stack-prod.env --project-name $stack-test -f stacks/$stack/docker-compose.yml up -d"

        # Check status
        log "Checking container status..."
        ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
          "cd /home/$vps_user/strut && docker compose --project-name $stack-test -f stacks/$stack/docker-compose.yml ps"
        ;;
      3)
        log "Skipping test for $stack"
        continue
        ;;
      *)
        warn "Invalid choice. Skipping test for $stack"
        continue
        ;;
    esac

    echo ""
    if ! confirm "Test successful?"; then
      warn "Test failed for $stack"
      echo "Review logs and fix issues before continuing."
      if [ "$choice" = "1" ]; then
        echo "Run: docker compose --project-name $stack-test -f $compose_file logs --follow"
      else
        echo "Run: ssh $vps_user@$vps_host 'cd /home/$vps_user/strut && docker compose --project-name $stack-test -f stacks/$stack/docker-compose.yml logs --follow'"
      fi

      if confirm "Stop test deployment and exit?"; then
        if [ "$choice" = "1" ]; then
          docker compose --project-name "$stack-test" -f "$compose_file" down
        else
          ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
            "cd /home/$vps_user/strut && docker compose --project-name $stack-test -f stacks/$stack/docker-compose.yml down"
        fi
        exit 1
      fi
    else
      ok "Test successful for $stack"

      # Clean up test deployment
      if confirm "Stop test deployment?"; then
        if [ "$choice" = "1" ]; then
          log "Stopping local test deployment..."
          docker compose --project-name "$stack-test" -f "$compose_file" down
        else
          log "Stopping VPS test deployment..."
          ssh_exec "$vps_user" "$vps_host" "$ssh_port" "$ssh_key" \
            "cd /home/$vps_user/strut && docker compose --project-name $stack-test -f stacks/$stack/docker-compose.yml down"
        fi
      fi
    fi
  done

  ok "All tests complete"
  echo ""
  if ! confirm "Continue to cutover?"; then
    log "Migration paused. Fix any issues and run wizard again to continue."
    exit 0
  fi
}
