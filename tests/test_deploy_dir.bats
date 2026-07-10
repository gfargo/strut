#!/usr/bin/env bats
# ==================================================
# tests/test_deploy_dir.bats — resolve_deploy_dir() unit tests
# ==================================================
# Covers OSS-323: canonical VPS deploy-dir resolver.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils
}

teardown() {
  common_teardown
}

# ── resolve_deploy_dir ────────────────────────────────────────────────────────

@test "resolve_deploy_dir: honors VPS_DEPLOY_DIR when set" {
  export VPS_DEPLOY_DIR="/opt/stacks"
  run resolve_deploy_dir
  [ "$status" -eq 0 ]
  [ "$output" = "/opt/stacks" ]
}

@test "resolve_deploy_dir: falls back to /home/\$VPS_USER/strut" {
  unset VPS_DEPLOY_DIR
  export VPS_USER="deploy"
  run resolve_deploy_dir
  [ "$status" -eq 0 ]
  [ "$output" = "/home/deploy/strut" ]
}

@test "resolve_deploy_dir: defaults user to ubuntu when VPS_USER unset" {
  unset VPS_DEPLOY_DIR
  unset VPS_USER
  run resolve_deploy_dir
  [ "$status" -eq 0 ]
  [ "$output" = "/home/ubuntu/strut" ]
}

@test "resolve_deploy_dir: VPS_DEPLOY_DIR takes priority over VPS_USER" {
  export VPS_DEPLOY_DIR="/custom/path"
  export VPS_USER="someuser"
  run resolve_deploy_dir
  [ "$status" -eq 0 ]
  [ "$output" = "/custom/path" ]
}

@test "resolve_deploy_dir: handles empty-string VPS_DEPLOY_DIR as unset" {
  export VPS_DEPLOY_DIR=""
  export VPS_USER="gfargo"
  run resolve_deploy_dir
  [ "$status" -eq 0 ]
  [ "$output" = "/home/gfargo/strut" ]
}

@test "resolve_deploy_dir: rejects VPS_DEPLOY_DIR containing spaces" {
  export VPS_DEPLOY_DIR="/opt/my stacks"
  run resolve_deploy_dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"VPS_DEPLOY_DIR"* ]]
  [[ "$output" == *"spaces"* ]]
}
