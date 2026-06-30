#!/usr/bin/env bats
# ==================================================
# tests/test_github_action.bats — Static analysis of action.yml
# ==================================================
# Verifies that action.yml declares the expected inputs, uses the composite
# runner, and contains no patterns that would leak secrets to logs.

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ACTION_FILE="$CLI_ROOT/action.yml"
}

# ── Presence and structure ────────────────────────────────────────────────────

@test "action.yml exists at repo root" {
  [ -f "$ACTION_FILE" ]
}

@test "action.yml uses composite runner" {
  grep -q "using: composite" "$ACTION_FILE"
}

@test "action.yml declares 'name:' field" {
  grep -qE "^name:" "$ACTION_FILE"
}

@test "action.yml declares 'description:' field" {
  grep -qE "^description:" "$ACTION_FILE"
}

# ── Required inputs ───────────────────────────────────────────────────────────

@test "action.yml declares 'stack' input" {
  grep -q "stack:" "$ACTION_FILE"
}

@test "action.yml declares 'command' input" {
  grep -q "command:" "$ACTION_FILE"
}

@test "action.yml declares 'env' input" {
  grep -q "  env:" "$ACTION_FILE"
}

@test "action.yml declares 'host' input" {
  grep -q "host:" "$ACTION_FILE"
}

@test "action.yml declares 'ssh-key' input" {
  grep -q "ssh-key:" "$ACTION_FILE"
}

@test "action.yml declares 'ssh-port' input" {
  grep -q "ssh-port:" "$ACTION_FILE"
}

@test "action.yml declares 'user' input" {
  grep -q "user:" "$ACTION_FILE"
}

@test "action.yml declares 'deploy-dir' input" {
  grep -q "deploy-dir:" "$ACTION_FILE"
}

@test "action.yml declares 'services' input" {
  grep -q "services:" "$ACTION_FILE"
}

@test "action.yml declares 'strict' input" {
  grep -q "strict:" "$ACTION_FILE"
}

@test "action.yml declares 'dry-run' input" {
  grep -q "dry-run:" "$ACTION_FILE"
}

@test "action.yml declares 'version' input" {
  grep -q "version:" "$ACTION_FILE"
}

@test "action.yml declares 'env-vars' input" {
  grep -q "env-vars:" "$ACTION_FILE"
}

# ── Secret hygiene: no plaintext secret leakage ───────────────────────────────

@test "action.yml does not echo the ssh-key input directly" {
  if grep -nE "echo.*ssh.key|echo.*SSH_KEY" "$ACTION_FILE" | grep -v "^[0-9]*:.*#"; then
    echo "Found unsafe echo of ssh-key in action.yml" >&2
    return 1
  fi
}

@test "action.yml does not use 'set -x' (would expose env vars in logs)" {
  if grep -nE "^\s+set -x|^\s+set .*x" "$ACTION_FILE" | grep -v "^[0-9]*:.*#"; then
    echo "Found 'set -x' in action.yml — this would print secret values to logs" >&2
    return 1
  fi
}

@test "action.yml does not cat the key file to stdout" {
  if grep -nE "cat.*strut_deploy_key|cat.*STRUT_KEY" "$ACTION_FILE" | grep -v "^[0-9]*:.*#"; then
    echo "Found 'cat' of SSH key file in action.yml" >&2
    return 1
  fi
}

@test "action.yml writes SSH key via printf, not echo" {
  grep -q "printf.*STRUT_SSH_KEY_CONTENTS\|printf.*ssh.key" "$ACTION_FILE"
}

# ── Env file path ─────────────────────────────────────────────────────────────

@test "action.yml materializes env file with leading dot (.<env>.env pattern)" {
  grep -qE '"\./\.\$\{?INPUT_ENV' "$ACTION_FILE"
}

# ── Flags mapped correctly ────────────────────────────────────────────────────

@test "action.yml maps --strict flag" {
  grep -q -- "--strict" "$ACTION_FILE"
}

@test "action.yml maps --dry-run flag" {
  grep -q -- "--dry-run" "$ACTION_FILE"
}

@test "action.yml maps --services flag" {
  grep -q -- "--services" "$ACTION_FILE"
}

@test "action.yml maps --env flag" {
  grep -q -- "--env" "$ACTION_FILE"
}

# ── Install and verify steps ──────────────────────────────────────────────────

@test "action.yml installs strut via install.sh" {
  grep -q "install.sh" "$ACTION_FILE"
}

@test "action.yml verifies strut version after install" {
  grep -q "strut --version" "$ACTION_FILE"
}

@test "action.yml uses STRUT_BRANCH env var to pin version" {
  grep -q "STRUT_BRANCH" "$ACTION_FILE"
}

# ── SSH key file ──────────────────────────────────────────────────────────────

@test "action.yml writes SSH key to RUNNER_TEMP (no spaces in path)" {
  grep -q "RUNNER_TEMP" "$ACTION_FILE"
}

@test "action.yml sets 600 permissions on SSH key file" {
  grep -q "chmod 600" "$ACTION_FILE"
}

# ── Example workflow ──────────────────────────────────────────────────────────

@test "example workflow template exists" {
  [ -f "$CLI_ROOT/templates/.github/workflows/strut-deploy.yml" ]
}

@test "example workflow references gfargo/strut-action" {
  grep -q "gfargo/strut-action" "$CLI_ROOT/templates/.github/workflows/strut-deploy.yml"
}
