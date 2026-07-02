#!/usr/bin/env bats
# ==================================================
# tests/test_volguard.bats — Tests for volume-path guard helpers in lib/diff.sh
# ==================================================
# Tests diff_extract_volume_vars, diff_extract_named_volumes,
# diff_detect_destructive, diff_detect_volume_renames, and
# _diff_is_volume_heuristic_var.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/diff.sh"
}

teardown() {
  common_teardown
}

# ── diff_extract_volume_vars ──────────────────────────────────────────────────

@test "diff_extract_volume_vars: extracts var from \${VAR:-default}/path form" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
'
  result=$(diff_extract_volume_vars "$compose")
  [[ "$result" == *"INSTALL_DIR"* ]]
}

@test "diff_extract_volume_vars: extracts var from plain \$VAR/path form" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - $PGDATA_DIR/postgres:/var/lib/postgresql/data
'
  result=$(diff_extract_volume_vars "$compose")
  [[ "$result" == *"PGDATA_DIR"* ]]
}

@test "diff_extract_volume_vars: named-volume-only compose → empty output" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - postgres_data:/var/lib/postgresql/data
volumes:
  postgres_data:
'
  result=$(diff_extract_volume_vars "$compose")
  [ -z "$result" ]
}

@test "diff_extract_volume_vars: multiple bind-mount vars extracted and deduped" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
  redis:
    image: redis:7
    volumes:
      - ${INSTALL_DIR:-./plane}/data/redis:/data
  app:
    image: myapp:latest
    volumes:
      - ${APP_DATA_DIR}/uploads:/app/uploads
'
  result=$(diff_extract_volume_vars "$compose")
  [[ "$result" == *"INSTALL_DIR"* ]]
  [[ "$result" == *"APP_DATA_DIR"* ]]
  # INSTALL_DIR appears twice in compose but should only appear once in output
  count=$(echo "$result" | grep -c "^INSTALL_DIR$")
  [ "$count" -eq 1 ]
}

@test "diff_extract_volume_vars: ignores non-bind-mount entries" {
  local compose='services:
  app:
    image: myapp:latest
    volumes:
      - ./config:/app/config:ro
      - named_vol:/app/data
volumes:
  named_vol:
'
  result=$(diff_extract_volume_vars "$compose")
  # ./config doesn't start with $ — should be empty
  [ -z "$result" ]
}

# ── diff_extract_named_volumes ────────────────────────────────────────────────

@test "diff_extract_named_volumes: extracts top-level volume keys" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - postgres_data:/var/lib/postgresql/data
  redis:
    image: redis:7
    volumes:
      - redis_data:/data
volumes:
  postgres_data:
  redis_data:
  nginx_certs:
'
  result=$(diff_extract_named_volumes "$compose")
  [[ "$result" == *"postgres_data"* ]]
  [[ "$result" == *"redis_data"* ]]
  [[ "$result" == *"nginx_certs"* ]]
}

@test "diff_extract_named_volumes: no volumes block → empty output" {
  local compose='services:
  app:
    image: myapp:latest
'
  result=$(diff_extract_named_volumes "$compose")
  [ -z "$result" ]
}

@test "diff_extract_named_volumes: does not include service-level volume entries" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR}/db:/var/lib/postgresql/data
volumes:
  redis_data:
'
  result=$(diff_extract_named_volumes "$compose")
  [[ "$result" == *"redis_data"* ]]
  # INSTALL_DIR is a bind-mount var, not a named volume
  [[ "$result" != *"INSTALL_DIR"* ]]
}

# ── _diff_is_volume_heuristic_var ────────────────────────────────────────────

@test "_diff_is_volume_heuristic_var: matches PGDATA" {
  run _diff_is_volume_heuristic_var "PGDATA"
  [ "$status" -eq 0 ]
}

@test "_diff_is_volume_heuristic_var: matches INSTALL_DIR" {
  run _diff_is_volume_heuristic_var "INSTALL_DIR"
  [ "$status" -eq 0 ]
}

@test "_diff_is_volume_heuristic_var: matches *_DATA_DIR suffix" {
  run _diff_is_volume_heuristic_var "NEO4J_DATA_DIR"
  [ "$status" -eq 0 ]
}

@test "_diff_is_volume_heuristic_var: matches *_DATA_PATH suffix" {
  run _diff_is_volume_heuristic_var "POSTGRES_DATA_PATH"
  [ "$status" -eq 0 ]
}

@test "_diff_is_volume_heuristic_var: matches *_PATH suffix" {
  run _diff_is_volume_heuristic_var "UPLOADS_PATH"
  [ "$status" -eq 0 ]
}

@test "_diff_is_volume_heuristic_var: does not match LOG_LEVEL" {
  run _diff_is_volume_heuristic_var "LOG_LEVEL"
  [ "$status" -ne 0 ]
}

@test "_diff_is_volume_heuristic_var: does not match APP_PORT" {
  run _diff_is_volume_heuristic_var "APP_PORT"
  [ "$status" -ne 0 ]
}

@test "_diff_is_volume_heuristic_var: does not match DATABASE_URL" {
  run _diff_is_volume_heuristic_var "DATABASE_URL"
  [ "$status" -ne 0 ]
}

# ── diff_detect_destructive ──────────────────────────────────────────────────

@test "diff_detect_destructive: CHANGE on compose-referenced var → emitted" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
'
  # Simulate diff_env_content output: INSTALL_DIR changed
  local env_diff
  env_diff=$(printf 'CHANGE\x1fINSTALL_DIR\x1f\x1f/opt/plane')
  result=$(diff_detect_destructive "$env_diff" "$compose")
  [[ "$result" == *"INSTALL_DIR"* ]]
  [[ "$result" == *"CHANGE"* ]]
}

@test "diff_detect_destructive: CHANGE on non-volume var → not emitted" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
'
  local env_diff
  env_diff=$(printf 'CHANGE\x1fLOG_LEVEL\x1fold\x1fnew')
  result=$(diff_detect_destructive "$env_diff" "$compose")
  [ -z "$result" ]
}

@test "diff_detect_destructive: COMPOSE_PROJECT_NAME CHANGE → always emitted" {
  local compose='services:
  app:
    image: myapp:latest
'
  local env_diff
  env_diff=$(printf 'CHANGE\x1fCOMPOSE_PROJECT_NAME\x1fold-project\x1fnew-project')
  result=$(diff_detect_destructive "$env_diff" "$compose")
  [[ "$result" == *"COMPOSE_PROJECT_NAME"* ]]
}

@test "diff_detect_destructive: heuristic var (PGDATA) CHANGE → emitted" {
  local compose='services:
  db:
    image: postgres:15
'
  local env_diff
  env_diff=$(printf 'CHANGE\x1fPGDATA\x1f/old/path\x1f/new/path')
  result=$(diff_detect_destructive "$env_diff" "$compose")
  [[ "$result" == *"PGDATA"* ]]
}

@test "diff_detect_destructive: heuristic var (NEO4J_DATA_DIR) ADD → emitted" {
  local compose='services:
  neo4j:
    image: neo4j:5
'
  local env_diff
  env_diff=$(printf 'ADD\x1fNEO4J_DATA_DIR\x1f\x1f/opt/neo4j/data')
  result=$(diff_detect_destructive "$env_diff" "$compose")
  [[ "$result" == *"NEO4J_DATA_DIR"* ]]
}

@test "diff_detect_destructive: empty env_diff → empty output" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
'
  result=$(diff_detect_destructive "" "$compose")
  [ -z "$result" ]
}

@test "diff_detect_destructive: identical vars → empty output" {
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
'
  # No diff rows → nothing to flag
  result=$(diff_detect_destructive "" "$compose")
  [ -z "$result" ]
}

@test "diff_detect_destructive: unset→set transition for compose var is flagged (ADD)" {
  # Remote env has no INSTALL_DIR (treated as absent); local adds it
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
'
  local env_diff
  env_diff=$(printf 'ADD\x1fINSTALL_DIR\x1f\x1f/opt/plane')
  result=$(diff_detect_destructive "$env_diff" "$compose")
  [[ "$result" == *"INSTALL_DIR"* ]]
  [[ "$result" == *"ADD"* ]]
}

# ── diff_detect_volume_renames ───────────────────────────────────────────────

@test "diff_detect_volume_renames: new named volume → ADD row" {
  local local_compose='services:
  db:
    image: postgres:15
    volumes:
      - postgres_data:/var/lib/postgresql/data
volumes:
  postgres_data:
  new_volume:
'
  local remote_compose='services:
  db:
    image: postgres:15
    volumes:
      - postgres_data:/var/lib/postgresql/data
volumes:
  postgres_data:
'
  result=$(diff_detect_volume_renames "$local_compose" "$remote_compose")
  [[ "$result" == *"ADD"* ]]
  [[ "$result" == *"new_volume"* ]]
}

@test "diff_detect_volume_renames: removed named volume → REMOVE row" {
  local local_compose='services:
  db:
    image: postgres:15
volumes:
  postgres_data:
'
  local remote_compose='services:
  db:
    image: postgres:15
volumes:
  postgres_data:
  old_cache:
'
  result=$(diff_detect_volume_renames "$local_compose" "$remote_compose")
  [[ "$result" == *"REMOVE"* ]]
  [[ "$result" == *"old_cache"* ]]
}

@test "diff_detect_volume_renames: identical named volumes → empty output" {
  local same_compose='services:
  db:
    image: postgres:15
volumes:
  postgres_data:
  redis_data:
'
  result=$(diff_detect_volume_renames "$same_compose" "$same_compose")
  [ -z "$result" ]
}

@test "diff_detect_volume_renames: both empty → empty output" {
  result=$(diff_detect_volume_renames "" "")
  [ -z "$result" ]
}

# ── _diff_render_destructive_text ────────────────────────────────────────────

@test "_diff_render_destructive_text: shows DATA-DESTRUCTIVE CHANGES header" {
  local tsv
  tsv=$(printf 'CHANGE\x1fINSTALL_DIR\x1f\x1f/opt/plane')
  result=$(_diff_render_destructive_text "$tsv")
  [[ "$result" == *"DATA-DESTRUCTIVE"* ]]
}

@test "_diff_render_destructive_text: CHANGE shows old→new arrow" {
  local tsv
  tsv=$(printf 'CHANGE\x1fINSTALL_DIR\x1f./plane\x1f/opt/plane')
  result=$(_diff_render_destructive_text "$tsv")
  [[ "$result" == *"INSTALL_DIR"* ]]
  [[ "$result" == *"→"* ]]
}

@test "_diff_render_destructive_text: ADD shows + prefix" {
  local tsv
  tsv=$(printf 'ADD\x1fINSTALL_DIR\x1f\x1f/opt/plane')
  result=$(_diff_render_destructive_text "$tsv")
  [[ "$result" == *"+"* ]]
  [[ "$result" == *"INSTALL_DIR"* ]]
}

@test "_diff_render_destructive_text: REMOVE shows - prefix" {
  local tsv
  tsv=$(printf 'REMOVE\x1fINSTALL_DIR\x1f./plane\x1f')
  result=$(_diff_render_destructive_text "$tsv")
  [[ "$result" == *"-"* ]]
  [[ "$result" == *"INSTALL_DIR"* ]]
}

@test "_diff_render_destructive_text: empty tsv → no output" {
  result=$(_diff_render_destructive_text "")
  [ -z "$result" ]
}

# ── Integration: diff_detect_destructive in context of diff_env_content ──────

@test "end-to-end: INSTALL_DIR change detected via diff_env_content pipeline" {
  local local_env='INSTALL_DIR=/opt/plane'
  local remote_env='# no INSTALL_DIR set (unset → ./plane default on VPS)'
  local compose='services:
  db:
    image: postgres:15
    volumes:
      - ${INSTALL_DIR:-./plane}/data/db:/var/lib/postgresql/data
'
  local env_diff
  env_diff=$(diff_env_content "$local_env" "$remote_env")
  result=$(diff_detect_destructive "$env_diff" "$compose")
  [[ "$result" == *"INSTALL_DIR"* ]]
}
