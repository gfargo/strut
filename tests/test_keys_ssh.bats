#!/usr/bin/env bats
# ==================================================
# tests/test_keys_ssh.bats — SSH key revoke safety tests (strut#216, strut#372)
# ==================================================
# Run:  bats tests/test_keys_ssh.bats
# Covers: keys_ssh_revoke — fingerprint-based matching (not comment-field
#         matching, which silently removed nothing whenever the on-disk
#         comment didn't equal the bare username — strut#372), quote-safety,
#         backup creation, last-admin-key guard, and rotation (add-then-
#         revoke) not deleting both old and new keys.
#
# A fake `ssh` executable is placed at the front of PATH so both the direct
# `ssh ...` call in keys_ssh_revoke/keys_ssh_add and the `timeout ... ssh ...`
# health check in validate_vps_connection run the remote script locally
# against a fake $HOME instead of touching a real host.
#
# Keys are REAL ed25519 keypairs (not placeholder base64 blobs) because the
# fix under test matches VPS authorized_keys entries by fingerprint
# (ssh-keygen -lf), which requires parseable key material.

setup() {
  export CLI_ROOT
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  STACK="test-sshrevoke-$$"

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    skip "ssh-keygen not available in this environment"
  fi

  mkdir -p "$TEST_TMP/bin" "$TEST_TMP/genkeys"
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

  declare -gA GENERATED_FP=()
}

teardown() {
  rm -rf "$CLI_ROOT/stacks/test-sshrevoke-"*
  rm -rf "$TEST_TMP"
}

# _gen_pubkey_line <comment> — generates a real ed25519 keypair with the
# given comment, appends its public key line to authorized_keys, and records
# its real fingerprint in GENERATED_FP[<comment>] for write_ssh_keys_metadata
# to pick up.
_gen_pubkey_line() {
  local comment="$1"
  local path="$TEST_TMP/genkeys/${comment//[^A-Za-z0-9_]/_}-$RANDOM"
  ssh-keygen -t ed25519 -C "$comment" -f "$path" -N "" -q
  cat "$path.pub" >> "$HOME/.ssh/authorized_keys"
  GENERATED_FP["$comment"]=$(ssh-keygen -lf "$path.pub" | awk '{print $2}')
}

# write_authorized_keys <comment1> <comment2> ...
# Populates $HOME/.ssh/authorized_keys with one real ed25519 key per comment.
write_authorized_keys() {
  : > "$HOME/.ssh/authorized_keys"
  local comment
  for comment in "$@"; do
    _gen_pubkey_line "$comment"
  done
}

# write_ssh_keys_metadata <username1[:comment1]> <username2[:comment2]> ...
# Populates the stack's ssh-keys.json with one entry per username, using the
# REAL fingerprint recorded by _gen_pubkey_line. Pass "username:comment" when
# the on-disk key comment differs from the username (the exact scenario that
# broke comment-based matching) — defaults to using the username itself as
# the lookup key into GENERATED_FP.
write_ssh_keys_metadata() {
  ensure_keys_dir "$STACK"
  local keys_dir metadata_file
  keys_dir=$(get_keys_dir "$STACK")
  metadata_file="$keys_dir/ssh-keys.json"

  local entries="[]"
  local spec username comment fp
  for spec in "$@"; do
    username="${spec%%:*}"
    comment="${spec#*:}"
    [ "$comment" = "$spec" ] && comment="$username"
    fp="${GENERATED_FP[$comment]:-fp-missing-$username}"
    entries=$(echo "$entries" | jq --arg u "$username" --arg fp "$fp" '. + [{"username": $u, "fingerprint": $fp}]')
  done

  jq --argjson entries "$entries" '.ssh_keys = $entries' "$metadata_file" > "$metadata_file.tmp"
  mv "$metadata_file.tmp" "$metadata_file"
}

# ── keys_ssh_revoke: fingerprint-based matching (strut#372) ──────────────────

@test "keys_ssh_revoke: revoking 'ed' removes only that user's key, not every ssh-ed25519 line" {
  write_authorized_keys "ed" "eddie" "alice"
  write_ssh_keys_metadata "ed" "eddie" "alice"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "ed" --no-confirm
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [ "$(echo "$remaining" | grep -c '^ssh-')" -eq 2 ]
  [[ "$remaining" == *" eddie"* ]]
  [[ "$remaining" == *" alice"* ]]
  [[ "$remaining" != *" ed"$'\n'* ]]
  [[ "$remaining" != *" ed" ]]

  # Metadata updated: "ed" removed, others remain
  local keys_dir
  keys_dir=$(get_keys_dir "$STACK")
  run jq -r '.ssh_keys[].username' "$keys_dir/ssh-keys.json"
  [[ "$output" != *$'\n'"ed"$'\n'* ]]
  [[ "$output" != "ed" ]]
  [[ "$output" == *"eddie"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "keys_ssh_revoke: short/common usernames ('al') don't collide with other users' keys" {
  write_authorized_keys "alan" "al" "alice"
  write_ssh_keys_metadata "alan" "al" "alice"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "al" --no-confirm
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [ "$(echo "$remaining" | grep -c '^ssh-')" -eq 2 ]
  [[ "$remaining" == *" alan"* ]]
  [[ "$remaining" == *" alice"* ]]
  [[ "$remaining" != *" al"$'\n'* ]]
  [[ "$remaining" != *" al" ]]
}

# ── Regression: comment field mismatch (the actual strut#372 bug) ────────────

@test "keys_ssh_revoke: removes the key even when the on-disk comment is 'username@stack', not the bare username" {
  # This is exactly how keys_ssh_add --generate names keys (ssh-keygen -C
  # "$username@$stack"), which is why $NF == username comment matching
  # never matched anything and revoke silently removed nothing.
  local comment="ed@$STACK"
  write_authorized_keys "$comment" "eddie"
  write_ssh_keys_metadata "ed:$comment" "eddie"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "ed" --no-confirm
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [ "$(echo "$remaining" | grep -c '^ssh-')" -eq 1 ]
  [[ "$remaining" == *" eddie"* ]]
  [[ "$remaining" != *"$comment"* ]]
}

@test "keys_ssh_revoke: removes the key even when the on-disk comment doesn't mention the username at all" {
  # Simulates a key added via --key-file whose comment is unrelated to the
  # tracked username (e.g. someone's default id_ed25519.pub comment).
  write_authorized_keys "someone@their-laptop" "eddie"
  write_ssh_keys_metadata "ed:someone@their-laptop" "eddie"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "ed" --no-confirm
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [ "$(echo "$remaining" | grep -c '^ssh-')" -eq 1 ]
  [[ "$remaining" == *" eddie"* ]]
  [[ "$remaining" != *"someone@their-laptop"* ]]
}

@test "keys_ssh_revoke: fails loudly (does not report success) when no authorized_keys entry matches the fingerprint" {
  write_authorized_keys "eddie"
  # Metadata claims a fingerprint that isn't actually on the VPS.
  write_ssh_keys_metadata "ed:nonexistent-comment-never-generated"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "ed" --no-confirm
  [ "$status" -ne 0 ]

  # authorized_keys must be untouched — eddie's key still present
  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [[ "$remaining" == *" eddie"* ]]
}

# ── keys_ssh_rotate: old and new keys never share a fingerprint ──────────────

@test "keys_ssh_rotate: revokes the old key and leaves exactly the new key behind" {
  # keys_ssh_add --generate calls ssh-keygen for real; keys_ssh_rotate then
  # verifies access with the new key via validate_vps_connection, which in
  # this test harness is also routed through the fake ssh wrapper and always
  # succeeds. Seed the "old" key with the same comment convention the product
  # uses (username@stack) so this also proves rotation doesn't rely on
  # comment matching to distinguish old from new.
  local old_comment="rotator@$STACK"
  write_authorized_keys "$old_comment"
  write_ssh_keys_metadata "rotator:$old_comment"

  run keys_ssh_rotate "$STACK" "$ENV_FILE" "rotator" --force
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  # Old key gone, exactly one (the new) key remains.
  [ "$(echo "$remaining" | grep -c '^ssh-')" -eq 1 ]
  [[ "$remaining" == *"rotator@$STACK"* ]]

  # Metadata reflects the new key's fingerprint, not the old one.
  local keys_dir new_fp_in_metadata new_fp_on_disk
  keys_dir=$(get_keys_dir "$STACK")
  new_fp_in_metadata=$(jq -r '.ssh_keys[] | select(.username == "rotator") | .fingerprint' "$keys_dir/ssh-keys.json")
  new_fp_on_disk=$(ssh-keygen -lf <(echo "$remaining") | awk '{print $2}')
  [ "$new_fp_in_metadata" = "$new_fp_on_disk" ]
  [ "$new_fp_in_metadata" != "${GENERATED_FP[$old_comment]}" ]
}

# ── keys_ssh_revoke: quote safety ─────────────────────────────────────────────

@test "keys_ssh_revoke: username containing a single quote is revoked safely, without shell injection" {
  write_authorized_keys "ed" "obrien"
  write_ssh_keys_metadata "o'brien:obrien" "ed"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "o'brien" --no-confirm
  [ "$status" -eq 0 ]

  local remaining
  remaining=$(cat "$HOME/.ssh/authorized_keys")
  [ "$(echo "$remaining" | grep -c '^ssh-')" -eq 1 ]
  [[ "$remaining" == *" ed"* ]]
  [[ "$remaining" != *"obrien"* ]]
}

# ── keys_ssh_revoke: backup safety ───────────────────────────────────────────

@test "keys_ssh_revoke: creates authorized_keys.backup before mutating" {
  write_authorized_keys "ed" "eddie"
  write_ssh_keys_metadata "ed" "eddie"

  run keys_ssh_revoke "$STACK" "$ENV_FILE" "ed" --no-confirm
  [ "$status" -eq 0 ]

  [ -f "$HOME/.ssh/authorized_keys.backup" ]
  run cat "$HOME/.ssh/authorized_keys.backup"
  [[ "$output" == *" ed"* ]]
  [[ "$output" == *" eddie"* ]]
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
