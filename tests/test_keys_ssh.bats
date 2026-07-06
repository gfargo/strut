#!/usr/bin/env bats
# ==================================================
# tests/test_keys_ssh.bats — SSH key revoke safety tests (OSS-470 / strut#216)
# ==================================================
# Run:  bats tests/test_keys_ssh.bats
# Covers: keys_ssh_revoke — exact comment-field matching (not substring-of-line),
#         quote-injection safety, backup creation, last-admin-key guard.
#
# A fake `ssh` executable is placed at the front of PATH so both the direct
# `ssh ...` call in keys_ssh_revoke and the `timeout ... ssh ...` health check
# in validate_vps_connection run the remote script locally against a fake
# $HOME instead of touching a real host.

setup() {
  export CLI_ROOT
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  STACK="test-sshrevoke-$$"

  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
last="${@: -1}"
exec bash -c "$last"
EOF
  chmod +x "$TEST_TMP/bin/ssh"
  export PATH="$TEST_TMP/bin:$PATH"

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh"

  source "$CLI_ROOT/lib/utils.sh"
  # Override fail() so it returns rather than exits — allows testing error paths
  fail() { echo "$1" >&2; return 1; }
  error() { echo "$1" >&2; }
  warn() { echo "$1" >&2; }

  source "$CLI_ROOT/lib/keys.sh"

  ENV_FILE="$TEST_TMP/.env"
  echo "VPS_HOST=fakehost" > "$ENV_FILE"
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-sshrevoke-"*
  rm -rf "$TEST_TMP"
}

# write_authorized_keys <comment1> <comment2> ...
# Populates $HOME/.ssh/authorized_keys with one ssh-ed25519 line per comment.
write_authorized_keys() {
  : > "$HOME/.ssh/authorized_keys"
  local comment
  for comment in "$@"; do
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfakeblob$RANDOM $comment" >> "$HOME/.ssh/authorized_keys"
  done
}

# write_ssh_keys_metadata <username1> <username2> ...
# Populates the stack's ssh-keys.json with one entry per username.
write_ssh_keys_metadata() {
  ensure_keys_dir "$STACK"
  local keys_dir metadata_file
  keys_dir=$(get_keys_dir "$STACK")
  metadata_file="$keys_dir/ssh-keys.json"

  local entries="[]"
  local username
  for username in "$@"; do
    entries=$(echo "$entries" | jq --arg u "$username" '. + [{"username": $u, "fingerprint": ("fp-" + $u)}]')
  done

  jq --argjson entries "$entries" '.ssh_keys = $entries' "$metadata_file" > "$metadata_file.tmp"
  mv "$metadata_file.tmp" "$metadata_file"
}

# ── keys_ssh_revoke: exact comment-field matching ────────────────────────────

@test "keys_ssh_revoke: revoking 'ed' removes only that user's key, not every ssh-ed25519 line" {
  write_authorized_keys "ed" "eddie" "alice"
  write_ssh_keys_metadata "ed" "eddie" "alice"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "ed" --no-confirm
  [ "$status" -eq 0 ]

  run cat "$HOME/.ssh/authorized_keys"
  [[ "$output" != *" ed"$'\n'* ]] || false
  [[ "$output" != *$'\n'"ssh-ed25519"*" ed" ]]
  [[ "$output" == *" eddie" ]] || [[ "$output" == *" eddie"$'\n'* ]]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [ "$(echo "$remaining" | wc -l)" -eq 2 ]
  [[ "$remaining" == *"eddie"* ]]
  [[ "$remaining" == *"alice"* ]]
  [[ "$remaining" != *$'\n'"ssh-ed25519 "*" ed"$'\n'* ]]

  # Exact-match check: no remaining line's last field is exactly "ed"
  ! echo "$remaining" | awk '{print $NF}' | grep -qx "ed"

  # Metadata updated: "ed" removed, others remain
  local keys_dir
  keys_dir=$(get_keys_dir "$STACK")
  run jq -r '.ssh_keys[].username' "$keys_dir/ssh-keys.json"
  [[ "$output" != *$'\n'"ed"$'\n'* ]]
  [[ "$output" != "ed" ]]
  [[ "$output" == *"eddie"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "keys_ssh_revoke: short/common usernames ('al') don't collide with base64 or other comments" {
  write_authorized_keys "alan" "al" "alice"
  write_ssh_keys_metadata "alan" "al" "alice"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "al" --no-confirm
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [ "$(echo "$remaining" | wc -l)" -eq 2 ]
  ! echo "$remaining" | awk '{print $NF}' | grep -qx "al"
  echo "$remaining" | awk '{print $NF}' | grep -qx "alan"
  echo "$remaining" | awk '{print $NF}' | grep -qx "alice"
}

# ── keys_ssh_revoke: quote-injection safety ──────────────────────────────────

@test "keys_ssh_revoke: username containing a single quote is revoked safely, without shell injection" {
  write_authorized_keys "ed" "o'brien"
  write_ssh_keys_metadata "ed" "o'brien"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "o'brien" --no-confirm
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [ "$(echo "$remaining" | wc -l)" -eq 1 ]
  [[ "$remaining" == *"ed"* ]]
  [[ "$remaining" != *"o'brien"* ]]
}

# ── keys_ssh_revoke: backup safety ───────────────────────────────────────────

@test "keys_ssh_revoke: creates authorized_keys.backup before mutating" {
  write_authorized_keys "ed" "eddie"
  write_ssh_keys_metadata "ed" "eddie"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "ed" --no-confirm
  [ "$status" -eq 0 ]

  [ -f "$HOME/.ssh/authorized_keys.backup" ]
  run cat "$HOME/.ssh/authorized_keys.backup"
  [[ "$output" == *"ed"* ]]
  [[ "$output" == *"eddie"* ]]
}

# ── keys_ssh_revoke: last-admin-key guard ────────────────────────────────────

@test "keys_ssh_revoke: refuses to revoke the last remaining admin key without --force" {
  write_authorized_keys "solo"
  write_ssh_keys_metadata "solo"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "solo" --no-confirm
  [ "$status" -eq 1 ]

  # Key must survive — no mutation happened
  run cat "$HOME/.ssh/authorized_keys"
  [[ "$output" == *"solo"* ]]
  [ ! -f "$HOME/.ssh/authorized_keys.backup" ]
}

@test "keys_ssh_revoke: --force overrides the last-admin-key guard" {
  write_authorized_keys "solo"
  write_ssh_keys_metadata "solo"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "solo" --no-confirm --force
  [ "$status" -eq 0 ]

  run cat "$HOME/.ssh/authorized_keys"
  [ -z "$output" ]
}
