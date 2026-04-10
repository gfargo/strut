#!/usr/bin/env bash
# lib/backup/compare.sh — Database comparison utilities

# compare_neo4j_databases <stack> <env1> <env2>
# Compares Neo4j databases between two environments
set -euo pipefail

compare_neo4j_databases() {
  local stack="$1"
  local env1="$2"
  local env2="$3"

  log "Comparing Neo4j databases: $env1 vs $env2"

  # Get container names
  local container1="${stack}-${env1}-neo4j-1"
  local container2="${stack}-${env2}-neo4j-1"

  # Check containers exist
  if ! docker ps --filter "name=$container1" --format "{{.Names}}" | grep -q "$container1"; then
    error "Container not found: $container1"
    return 1
  fi

  if ! docker ps --filter "name=$container2" --format "{{.Names}}" | grep -q "$container2"; then
    error "Container not found: $container2"
    return 1
  fi

  # Get Neo4j credentials from env files
  local env1_file="$CLI_ROOT/.${env1}.env"
  local env2_file="$CLI_ROOT/.${env2}.env"

  [ -f "$env1_file" ] || fail "Env file not found: $env1_file"
  [ -f "$env2_file" ] || fail "Env file not found: $env2_file"

  local neo4j_password1
  neo4j_password1=$(grep "^NEO4J_PASSWORD=" "$env1_file" | cut -d= -f2- | tr -d '"' | tr -d "'")

  local neo4j_password2
  neo4j_password2=$(grep "^NEO4J_PASSWORD=" "$env2_file" | cut -d= -f2- | tr -d '"' | tr -d "'")

  # Wait for containers to be healthy
  log "Waiting for Neo4j containers to be ready..."
  local max_wait=60
  local waited=0

  while [ $waited -lt $max_wait ]; do
    local status1
    status1=$(docker ps --filter "name=$container1" --format "{{.Status}}" 2>/dev/null)
    local status2
    status2=$(docker ps --filter "name=$container2" --format "{{.Status}}" 2>/dev/null)

    if echo "$status1" | grep -q "healthy" && echo "$status2" | grep -q "healthy"; then
      break
    fi

    sleep 2
    waited=$((waited + 2))
  done

  if [ $waited -ge $max_wait ]; then
    warn "Containers may not be fully healthy yet, proceeding anyway..."
  fi

  # Query both databases
  log "Querying $env1 database..."
  local stats1
  stats1=$(docker exec "$container1" cypher-shell -u neo4j -p "$neo4j_password1" \
    "MATCH (n) WITH count(n) as nodes
     MATCH ()-[r]->() WITH nodes, count(r) as rels
     MATCH (n) WHERE n.uuid IS NOT NULL WITH nodes, rels, count(n) as nodes_with_uuid
     RETURN nodes, rels, nodes_with_uuid" 2>&1)

  if [ $? -ne 0 ]; then
    error "Failed to query $env1 database"
    echo "$stats1" >&2
    return 1
  fi

  log "Querying $env2 database..."
  local stats2
  stats2=$(docker exec "$container2" cypher-shell -u neo4j -p "$neo4j_password2" \
    "MATCH (n) WITH count(n) as nodes
     MATCH ()-[r]->() WITH nodes, count(r) as rels
     MATCH (n) WHERE n.uuid IS NOT NULL WITH nodes, rels, count(n) as nodes_with_uuid
     RETURN nodes, rels, nodes_with_uuid" 2>&1)

  if [ $? -ne 0 ]; then
    error "Failed to query $env2 database"
    echo "$stats2" >&2
    return 1
  fi

  # Parse results (skip header lines)
  local nodes1 rels1 uuid1
  read -r nodes1 rels1 uuid1 < <(echo "$stats1" | grep -E '^[0-9]' | head -1 | tr '|' ' ' | awk '{print $1, $2, $3}')

  local nodes2 rels2 uuid2
  read -r nodes2 rels2 uuid2 < <(echo "$stats2" | grep -E '^[0-9]' | head -1 | tr '|' ' ' | awk '{print $1, $2, $3}')

  # Display comparison
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Neo4j Database Comparison: $env1 vs $env2"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-25s %15s %15s %10s\n" "Metric" "$env1" "$env2" "Match"
  echo "──────────────────────────────────────────────────────────────"

  local nodes_match="✓"
  [ "$nodes1" != "$nodes2" ] && nodes_match="✗"
  printf "  %-25s %15s %15s %10s\n" "Total Nodes" "$nodes1" "$nodes2" "$nodes_match"

  local rels_match="✓"
  [ "$rels1" != "$rels2" ] && rels_match="✗"
  printf "  %-25s %15s %15s %10s\n" "Total Relationships" "$rels1" "$rels2" "$rels_match"

  local uuid_match="✓"
  [ "$uuid1" != "$uuid2" ] && uuid_match="✗"
  printf "  %-25s %15s %15s %10s\n" "Nodes with UUID" "$uuid1" "$uuid2" "$uuid_match"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Check if databases match
  if [ "$nodes1" = "$nodes2" ] && [ "$rels1" = "$rels2" ] && [ "$uuid1" = "$uuid2" ]; then
    ok "Databases match! Node count: $nodes1, Relationship count: $rels1"
    return 0
  else
    warn "Databases differ!"
    echo "  Differences:"
    [ "$nodes1" != "$nodes2" ] && echo "    • Node count: $env1 has $nodes1, $env2 has $nodes2 (diff: $((nodes2 - nodes1)))"
    [ "$rels1" != "$rels2" ] && echo "    • Relationship count: $env1 has $rels1, $env2 has $rels2 (diff: $((rels2 - rels1)))"
    [ "$uuid1" != "$uuid2" ] && echo "    • UUID nodes: $env1 has $uuid1, $env2 has $uuid2 (diff: $((uuid2 - uuid1)))"
    return 1
  fi
}

# compare_neo4j_labels <stack> <env1> <env2>
# Compares node label distribution between environments
compare_neo4j_labels() {
  local stack="$1"
  local env1="$2"
  local env2="$3"

  log "Comparing Neo4j node labels: $env1 vs $env2"

  local container1="${stack}-${env1}-neo4j-1"
  local container2="${stack}-${env2}-neo4j-1"

  # Get credentials
  local env1_file="$CLI_ROOT/.${env1}.env"
  local env2_file="$CLI_ROOT/.${env2}.env"

  local neo4j_password1
  neo4j_password1=$(grep "^NEO4J_PASSWORD=" "$env1_file" | cut -d= -f2- | tr -d '"' | tr -d "'")

  local neo4j_password2
  neo4j_password2=$(grep "^NEO4J_PASSWORD=" "$env2_file" | cut -d= -f2- | tr -d '"' | tr -d "'")

  # Query label counts
  log "Querying $env1 labels..."
  local labels1
  labels1=$(docker exec "$container1" cypher-shell -u neo4j -p "$neo4j_password1" \
    "CALL db.labels() YIELD label
     CALL apoc.cypher.run('MATCH (n:\`' + label + '\`) RETURN count(n) as count', {}) YIELD value
     RETURN label, value.count as count ORDER BY label" --format plain 2>&1)

  log "Querying $env2 labels..."
  local labels2
  labels2=$(docker exec "$container2" cypher-shell -u neo4j -p "$neo4j_password2" \
    "CALL db.labels() YIELD label
     CALL apoc.cypher.run('MATCH (n:\`' + label + '\`) RETURN count(n) as count', {}) YIELD value
     RETURN label, value.count as count ORDER BY label" --format plain 2>&1)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Node Label Distribution: $env1 vs $env2"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-30s %15s %15s %10s\n" "Label" "$env1" "$env2" "Match"
  echo "──────────────────────────────────────────────────────────────"

  # Parse and display results
  echo "$labels1" | grep -v "^label" | grep -v "^$" | while IFS='|' read -r label count1; do
    label=$(echo "$label" | xargs)
    count1=$(echo "$count1" | xargs)

    # Find matching label in env2
    local count2
    count2=$(echo "$labels2" | grep "^$label" | cut -d'|' -f2 | xargs)
    count2=${count2:-0}

    local match="✓"
    [ "$count1" != "$count2" ] && match="✗"

    printf "  %-30s %15s %15s %10s\n" "$label" "$count1" "$count2" "$match"
  done

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# compare_postgres_databases <stack> <env1> <env2>
# Compares Postgres databases between two environments
compare_postgres_databases() {
  local stack="$1"
  local env1="$2"
  local env2="$3"

  log "Comparing Postgres databases: $env1 vs $env2"

  local container1="${stack}-${env1}-postgres-1"
  local container2="${stack}-${env2}-postgres-1"

  # Check containers exist
  if ! docker ps --filter "name=$container1" --format "{{.Names}}" | grep -q "$container1"; then
    error "Container not found: $container1"
    return 1
  fi

  if ! docker ps --filter "name=$container2" --format "{{.Names}}" | grep -q "$container2"; then
    error "Container not found: $container2"
    return 1
  fi

  # Get Postgres credentials
  local env1_file="$CLI_ROOT/.${env1}.env"
  local env2_file="$CLI_ROOT/.${env2}.env"

  local pg_user1 pg_db1
  pg_user1=$(grep "^POSTGRES_USER=" "$env1_file" | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "postgres")
  pg_db1=$(grep "^POSTGRES_DB=" "$env1_file" | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "app_db")

  local pg_user2 pg_db2
  pg_user2=$(grep "^POSTGRES_USER=" "$env2_file" | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "postgres")
  pg_db2=$(grep "^POSTGRES_DB=" "$env2_file" | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "app_db")

  # Query table counts
  log "Querying $env1 database..."
  local tables1
  tables1=$(docker exec "$container1" psql -U "$pg_user1" -d "$pg_db1" -t -c \
    "SELECT schemaname || '.' || tablename as table_name,
            (SELECT count(*) FROM pg_catalog.pg_class c WHERE c.relname = tablename) as row_count
     FROM pg_tables
     WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
     ORDER BY table_name" 2>&1)

  log "Querying $env2 database..."
  local tables2
  tables2=$(docker exec "$container2" psql -U "$pg_user2" -d "$pg_db2" -t -c \
    "SELECT schemaname || '.' || tablename as table_name,
            (SELECT count(*) FROM pg_catalog.pg_class c WHERE c.relname = tablename) as row_count
     FROM pg_tables
     WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
     ORDER BY table_name" 2>&1)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Postgres Table Comparison: $env1 vs $env2"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-40s %15s %15s %10s\n" "Table" "$env1" "$env2" "Match"
  echo "──────────────────────────────────────────────────────────────"

  # Parse and display results
  echo "$tables1" | grep -v "^$" | while read -r table_name count1; do
    table_name=$(echo "$table_name" | xargs)
    count1=$(echo "$count1" | xargs)

    # Find matching table in env2
    local count2
    count2=$(echo "$tables2" | grep "^[[:space:]]*$table_name" | awk '{print $2}' | xargs)
    count2=${count2:-0}

    local match="✓"
    [ "$count1" != "$count2" ] && match="✗"

    printf "  %-40s %15s %15s %10s\n" "$table_name" "$count1" "$count2" "$match"
  done

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}
