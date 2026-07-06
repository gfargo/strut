#!/usr/bin/env bats
# ==================================================
# tests/test_keys_rotate.bats — Tests for key rotation fixes
# ==================================================
# Run:  bats tests/test_keys_rotate.bats
# Covers: keys_db_rotate arg forwarding, keys_db_rotate_postgres --dry-run/--force,
#         keys_ssh_rotate --dry-run/--force forwarding, keys_api_rotate/keys_api_generate
#         --force overwrite of an existing key, keys_github_rotate_vps_key arity fix
#         and --dry-run.

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"

  # lib/keys/db.sh and lib/keys/github.sh hardcode env_file="$CLI_ROOT/.prod.env"
  # (a real path at the repo root) — preserve any pre-existing file so a local
  # dev's own .prod.env can't be clobbered by these tests.
  if [ -f "$CLI_ROOT/.prod.env" ]; then
    cp "$CLI_ROOT/.prod.env" "$TEST_TMP/.prod.env.orig"
  fi

  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/keys.sh"
}

teardown() {
  rm -f "$CLI_ROOT/.prod.env" "$CLI_ROOT"/.prod.env.backup-* "$CLI_ROOT/.prod.env.tmp"
  if [ -f "$TEST_TMP/.prod.env.orig" ]; then
    cp "$TEST_TMP/.prod.env.orig" "$CLI_ROOT/.prod.env"
  fi
  rm -rf "$CLI_ROOT/stacks/test-keys-rotate-"*
  rm -rf "$TEST_TMP"
}

# ── keys_db_rotate: arg forwarding ────────────────────────────────────────────

@test "keys_db_rotate: forwards --dry-run and --force to keys_db_rotate_postgres" {
  local stack="test-keys-rotate-dbfwd-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"

  keys_db_rotate_postgres() { echo "POSTGRES_ARGS:$*"; }

  run keys_db_rotate "$stack" postgres --dry-run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSTGRES_ARGS:"*"--dry-run --force"* ]]
}

# ── keys_db_rotate_postgres: --dry-run / --force ─────────────────────────────

@test "keys_db_rotate_postgres: --dry-run performs no mutation" {
  local stack="test-keys-rotate-dbdry-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1

  printf 'POSTGRES_USER=app\nPOSTGRES_DB=app_db\nPOSTGRES_PASSWORD=oldpass\n' > "$CLI_ROOT/.prod.env"

  resolve_compose_cmd() { echo "resolve_compose_cmd must not be called in dry-run" >&2; return 1; }

  run keys_db_rotate_postgres "$stack" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]

  grep -q "POSTGRES_PASSWORD=oldpass" "$CLI_ROOT/.prod.env"
  ! compgen -G "$CLI_ROOT/.prod.env.backup-*" >/dev/null
}

@test "keys_db_rotate_postgres: --force skips confirm prompt" {
  local stack="test-keys-rotate-dbforce-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1

  printf 'POSTGRES_USER=app\nPOSTGRES_DB=app_db\nPOSTGRES_PASSWORD=oldpass\n' > "$CLI_ROOT/.prod.env"

  confirm() { return 1; }
  fakecompose() {
    if [ "$1" = "ps" ]; then
      echo "postgres Up"
    else
      cat >/dev/null
    fi
  }
  resolve_compose_cmd() { echo "fakecompose"; }

  run keys_db_rotate_postgres "$stack" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"password rotated successfully"* ]]

  grep -q "^POSTGRES_PASSWORD=oldpass$" "$CLI_ROOT/.prod.env" && return 1
  compgen -G "$CLI_ROOT/.prod.env.backup-*" >/dev/null
}

@test "keys_db_rotate_postgres: fails without touching DB when POSTGRES_PASSWORD isn't line-anchored" {
  local stack="test-keys-rotate-dbnoanchor-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1

  printf 'POSTGRES_USER=app\nPOSTGRES_DB=app_db\nexport POSTGRES_PASSWORD=oldpass\n' > "$CLI_ROOT/.prod.env"

  resolve_compose_cmd() { echo "resolve_compose_cmd must not be called" >&2; return 1; }

  run keys_db_rotate_postgres "$stack" --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to rotate"* ]]

  grep -q "^export POSTGRES_PASSWORD=oldpass$" "$CLI_ROOT/.prod.env"
  ! compgen -G "$CLI_ROOT/.prod.env.backup-*" >/dev/null
}

@test "keys_db_rotate_postgres: backup exists before ALTER USER runs" {
  local stack="test-keys-rotate-dbbackup-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1

  printf 'POSTGRES_USER=app\nPOSTGRES_DB=app_db\nPOSTGRES_PASSWORD=oldpass\n' > "$CLI_ROOT/.prod.env"

  fakecompose() {
    if [ "$1" = "ps" ]; then
      echo "postgres Up"
    else
      compgen -G "$CLI_ROOT/.prod.env.backup-*" >/dev/null || { echo "NO BACKUP YET" >&2; return 1; }
      cat >/dev/null
    fi
  }
  resolve_compose_cmd() { echo "fakecompose"; }
  confirm() { return 0; }

  run keys_db_rotate_postgres "$stack"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NO BACKUP YET"* ]]

  compgen -G "$CLI_ROOT/.prod.env.backup-*" >/dev/null
}

# ── keys_env_rotate: precondition / verification ─────────────────────────────

@test "keys_env_rotate: fails and makes no changes when a target var isn't line-anchored" {
  local stack="test-keys-rotate-envnoanchor-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1

  printf 'NEO4J_PASSWORD=oldneo\nPOSTGRES_PASSWORD=oldpg\n# API_SECRET_KEY=oldapi\n' > "$CLI_ROOT/.prod.env"

  run keys_env_rotate "$stack" --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to rotate"* ]]

  grep -q "^NEO4J_PASSWORD=oldneo$" "$CLI_ROOT/.prod.env"
  grep -q "^POSTGRES_PASSWORD=oldpg$" "$CLI_ROOT/.prod.env"
  grep -q "^# API_SECRET_KEY=oldapi$" "$CLI_ROOT/.prod.env"
  compgen -G "$CLI_ROOT/.prod.env.backup-*" >/dev/null
}

@test "keys_env_rotate: --force happy path rotates and verifies all three vars" {
  local stack="test-keys-rotate-envforce-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1

  printf 'NEO4J_PASSWORD=oldneo\nPOSTGRES_PASSWORD=oldpg\nAPI_SECRET_KEY=oldapi\n' > "$CLI_ROOT/.prod.env"

  run keys_env_rotate "$stack" --force
  [ "$status" -eq 0 ]

  grep -q "^NEO4J_PASSWORD=oldneo$" "$CLI_ROOT/.prod.env" && return 1
  grep -q "^POSTGRES_PASSWORD=oldpg$" "$CLI_ROOT/.prod.env" && return 1
  grep -q "^API_SECRET_KEY=oldapi$" "$CLI_ROOT/.prod.env" && return 1
  grep -q "^NEO4J_PASSWORD=" "$CLI_ROOT/.prod.env"
  grep -q "^POSTGRES_PASSWORD=" "$CLI_ROOT/.prod.env"
  grep -q "^API_SECRET_KEY=" "$CLI_ROOT/.prod.env"
}

# ── keys_ssh_rotate: --dry-run / --force forwarding ──────────────────────────

@test "keys_ssh_rotate: forwards --dry-run to revoke and add" {
  local stack="test-keys-rotate-sshdry-$$"
  local env_file="$TEST_TMP/fake.env"
  touch "$env_file"

  keys_ssh_revoke() { echo "REVOKE:$*" >> "$TEST_TMP/calls"; }
  keys_ssh_add() { echo "ADD:$*" >> "$TEST_TMP/calls"; }

  run keys_ssh_rotate "$stack" "$env_file" alice --dry-run
  [ "$status" -eq 0 ]

  grep -q "^REVOKE:.*--dry-run" "$TEST_TMP/calls"
  grep -q "^ADD:.*--dry-run" "$TEST_TMP/calls"
}

@test "keys_ssh_rotate: forwards --force to revoke and add, adding before revoking" {
  local stack="test-keys-rotate-sshforce-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/fake.env"
  echo "VPS_HOST=fakehost" > "$env_file"

  keys_ssh_add() {
    echo "ADD:$*" >> "$TEST_TMP/calls"
    local keys_dir
    keys_dir=$(get_keys_dir "$1")
    echo '{"ssh_keys":[{"username":"alice","fingerprint":"fp-new","key_file":"'"$TEST_TMP"'/fake-alice.pub"}],"last_updated":"x"}' > "$keys_dir/ssh-keys.json"
  }
  keys_ssh_revoke() { echo "REVOKE:$*" >> "$TEST_TMP/calls"; }
  validate_vps_connection() { return 0; }

  run keys_ssh_rotate "$stack" "$env_file" alice --force
  [ "$status" -eq 0 ]

  grep -q "^REVOKE:.*--force" "$TEST_TMP/calls"
  grep -q "^ADD:.*--force" "$TEST_TMP/calls"

  local add_line revoke_line
  add_line=$(grep -n "^ADD:" "$TEST_TMP/calls" | head -1 | cut -d: -f1)
  revoke_line=$(grep -n "^REVOKE:" "$TEST_TMP/calls" | head -1 | cut -d: -f1)
  [ "$add_line" -lt "$revoke_line" ]
}

@test "keys_ssh_rotate: does not revoke when add fails" {
  local stack="test-keys-rotate-sshaddfail-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/fake.env"
  echo "VPS_HOST=fakehost" > "$env_file"

  keys_ssh_add() { echo "ADD:$*" >> "$TEST_TMP/calls"; return 1; }
  keys_ssh_revoke() { echo "REVOKE:$*" >> "$TEST_TMP/calls"; }

  run keys_ssh_rotate "$stack" "$env_file" alice --force
  [ "$status" -ne 0 ]

  grep -q "^ADD:" "$TEST_TMP/calls"
  ! grep -q "^REVOKE:" "$TEST_TMP/calls"
}

@test "keys_ssh_rotate: does not revoke when new-key verification fails" {
  local stack="test-keys-rotate-sshverifyfail-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local env_file="$TEST_TMP/fake.env"
  echo "VPS_HOST=fakehost" > "$env_file"

  keys_ssh_add() {
    echo "ADD:$*" >> "$TEST_TMP/calls"
    local keys_dir
    keys_dir=$(get_keys_dir "$1")
    echo '{"ssh_keys":[{"username":"alice","fingerprint":"fp-new","key_file":"'"$TEST_TMP"'/fake-alice.pub"}],"last_updated":"x"}' > "$keys_dir/ssh-keys.json"
  }
  keys_ssh_revoke() { echo "REVOKE:$*" >> "$TEST_TMP/calls"; }
  validate_vps_connection() { return 1; }

  run keys_ssh_rotate "$stack" "$env_file" alice --force
  [ "$status" -ne 0 ]

  grep -q "^ADD:" "$TEST_TMP/calls"
  ! grep -q "^REVOKE:" "$TEST_TMP/calls"
}

# ── keys_api_rotate / keys_api_generate: --force overwrite ───────────────────

@test "keys_api_rotate: succeeds for an existing name" {
  local stack="test-keys-rotate-apirotate-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local keys_dir="$CLI_ROOT/stacks/$stack/keys"

  jq -n '{api_keys: [{name:"test-key", tier:"standard", created:"2024-01-01T00:00:00Z", rotated:"2024-01-01T00:00:00Z", expires:null, last_used:null, key_masked:"abc...xyz"}], last_updated:"2024-01-01T00:00:00Z"}' > "$keys_dir/api-keys.json"

  confirm() { return 0; }

  run keys_api_rotate "$stack" test-key
  [ "$status" -eq 0 ]
  [[ "$output" != *"already exists"* ]]

  local count
  count=$(jq '[.api_keys[] | select(.name == "test-key")] | length' "$keys_dir/api-keys.json")
  [ "$count" -eq 1 ]

  local rotated
  rotated=$(jq -r '.api_keys[] | select(.name == "test-key") | .rotated' "$keys_dir/api-keys.json")
  [ "$rotated" != "2024-01-01T00:00:00Z" ]
}

@test "keys_api_generate: --force overwrites an existing name" {
  local stack="test-keys-rotate-apiforce-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local keys_dir="$CLI_ROOT/stacks/$stack/keys"

  jq -n '{api_keys: [{name:"test-key", tier:"standard", created:"2024-01-01T00:00:00Z", rotated:"2024-01-01T00:00:00Z", expires:null, last_used:null, key_masked:"abc...xyz"}], last_updated:"2024-01-01T00:00:00Z"}' > "$keys_dir/api-keys.json"

  run keys_api_generate "$stack" test-key --tier standard --force
  [ "$status" -eq 0 ]
  [[ "$output" != *"already exists"* ]]
}

@test "keys_api_generate: without --force still rejects an existing name" {
  local stack="test-keys-rotate-apiguard-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  ensure_keys_dir "$stack" >/dev/null 2>&1
  local keys_dir="$CLI_ROOT/stacks/$stack/keys"

  jq -n '{api_keys: [{name:"test-key", tier:"standard", created:"2024-01-01T00:00:00Z", rotated:"2024-01-01T00:00:00Z", expires:null, last_used:null, key_masked:"abc...xyz"}], last_updated:"2024-01-01T00:00:00Z"}' > "$keys_dir/api-keys.json"

  run keys_api_generate "$stack" test-key --tier standard
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}

# ── keys_github_rotate_vps_key: arity fix / --dry-run ────────────────────────

@test "keys_github_rotate_vps_key: calls keys_ssh_add with correct arity" {
  local stack="test-keys-rotate-ghfix-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  printf 'VPS_HOST=127.0.0.1\nVPS_USER=ubuntu\n' > "$CLI_ROOT/.prod.env"

  keys_ssh_add() {
    echo "SSH_ADD_ARGS:$*" >> "$TEST_TMP/calls"
    local keys_dir
    keys_dir=$(get_keys_dir "$1")
    mkdir -p "$keys_dir"
    echo '{"ssh_keys":[{"username":"deploy-bot","key_file":"'"$TEST_TMP"'/fake-deploy-bot.pub"}],"last_updated":"x"}' > "$keys_dir/ssh-keys.json"
    touch "$TEST_TMP/fake-deploy-bot" "$TEST_TMP/fake-deploy-bot.pub"
  }
  gh() { echo "GH_CALLED:$*" >> "$TEST_TMP/calls"; }
  ssh() { return 1; }

  run keys_github_rotate_vps_key "$stack" --repos org/repo
  [ "$status" -eq 0 ]

  # arity: (stack, env_file, username, --generate, --key-name, <name>) — NOT
  # (stack, "deploy-bot", --generate) which crashed validate_env_file before the fix.
  grep -q "^SSH_ADD_ARGS:$stack $CLI_ROOT/.prod.env deploy-bot --generate --key-name vps-deploy-" "$TEST_TMP/calls"
}

@test "keys_github_rotate_vps_key: --dry-run performs no mutation" {
  local stack="test-keys-rotate-ghdry-$$"
  mkdir -p "$CLI_ROOT/stacks/$stack"
  printf 'VPS_HOST=127.0.0.1\nVPS_USER=ubuntu\n' > "$CLI_ROOT/.prod.env"

  keys_ssh_add() { echo "SHOULD NOT BE CALLED" >> "$TEST_TMP/calls"; }
  gh() { echo "SHOULD NOT BE CALLED" >> "$TEST_TMP/calls"; }

  run keys_github_rotate_vps_key "$stack" --repos org/repo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ ! -f "$TEST_TMP/calls" ]
}
