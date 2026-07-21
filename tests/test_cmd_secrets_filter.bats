#!/usr/bin/env bats
# ==================================================
# tests/test_cmd_secrets_filter.bats — Tests for `secrets-filter` (strut#178)
# ==================================================
# Transparent git clean/smudge filter for at-rest secrets encryption.
# Run:  bats tests/test_cmd_secrets_filter.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail()         { echo "FAIL: $1" >&2; return 1; }
  ok()           { echo "OK: $*"; }
  warn()         { echo "WARN: $*" >&2; }
  log()          { echo "LOG: $*"; }
  error()        { echo "ERROR: $*" >&2; }
  print_banner() { echo "== $* =="; }
  export -f fail ok warn log error print_banner

  source "$CLI_ROOT/lib/secrets_providers.sh"
  source "$CLI_ROOT/lib/cmd_secrets.sh"
  export -f _secrets_git_clean _secrets_git_smudge _secrets_filter_recipients_for

  # Fake age supporting both call shapes used here:
  #   streaming: age -e -R <rcpts>              (stdin -> stdout)
  #   file mode: age -d -i <id> -o <out> <in>   (used by smudge)
  # A plaintext body of "BADCIPHER" simulates a decrypt failure, so smudge's
  # passthrough fallback can be exercised without a real crypto failure.
  age() {
    local output="" input=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -e|-d) shift ;;
        -o)    output="$2"; shift 2 ;;
        -R)    shift 2 ;;
        -i)    shift 2 ;;
        *)     input="$1"; shift ;;
      esac
    done
    if [ -n "$input" ]; then
      grep -q "BADCIPHER" "$input" 2>/dev/null && return 1
      if [ -n "$output" ]; then cp "$input" "$output"; else cat "$input"; fi
    else
      cat
    fi
  }
  export -f age

  export HOME="$TEST_TMP/fakehome"
  mkdir -p "$HOME/.ssh" "$HOME/.age"

  export CLI_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/stacks/demo"
}

teardown() { common_teardown; }

# _path_without_age — echoes a PATH with every essential utility available
# via symlink EXCEPT age, so "age not installed" tests don't also break the
# git/mktemp/cat calls the functions under test still need internally.
_path_without_age() {
  local safe_bin="$TEST_TMP/safe-bin"
  mkdir -p "$safe_bin"
  local bin real
  for bin in bash sh git cat mktemp rm cp mkdir dirname basename grep sed mv chmod true false env; do
    real=$(command -v "$bin" 2>/dev/null) || continue
    ln -sf "$real" "$safe_bin/$bin"
  done
  echo "$safe_bin"
}

# ── _secrets_git_clean ───────────────────────────────────────────────────────

@test "_secrets_git_clean: fails when age is not installed" {
  unset -f age
  local empty_bin="$TEST_TMP/empty-bin"
  mkdir -p "$empty_bin"
  PATH="$empty_bin" run _secrets_git_clean "stacks/demo/.prod.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"age"* ]]
}

@test "_secrets_git_clean: fails when no recipients are configured anywhere" {
  run _secrets_git_clean "stacks/demo/.prod.env" <<< "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"recipients"* ]]
}

@test "_secrets_git_clean: uses the stack-dir .strut-recipients when present" {
  echo "age1qtest" > "$TEST_TMP/stacks/demo/.strut-recipients"
  run bash -c '_secrets_git_clean "stacks/demo/.prod.env" <<< "SECRET=1"'
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=1" ]
}

@test "_secrets_git_clean: falls back to project-root .strut-recipients" {
  echo "age1qtest" > "$TEST_TMP/.strut-recipients"
  run bash -c '_secrets_git_clean "stacks/demo/.prod.env" <<< "SECRET=1"'
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=1" ]
}

@test "_secrets_git_clean: falls back to self via ~/.ssh/id_ed25519.pub" {
  echo "ssh-ed25519 AAAA test" > "$HOME/.ssh/id_ed25519.pub"
  run bash -c '_secrets_git_clean "stacks/demo/.prod.env" <<< "SECRET=1"'
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=1" ]
}

@test "_secrets_git_clean: a project-root file (no stacks/ prefix) still resolves recipients" {
  echo "age1qtest" > "$TEST_TMP/.strut-recipients"
  run bash -c '_secrets_git_clean ".prod.env" <<< "SECRET=1"'
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=1" ]
}

# ── _secrets_git_smudge ──────────────────────────────────────────────────────

@test "_secrets_git_smudge: passes content through unchanged when no identity is available" {
  run bash -c 'echo "CIPHERTEXT" | _secrets_git_smudge'
  [ "$status" -eq 0 ]
  [ "$output" = "CIPHERTEXT" ]
}

@test "_secrets_git_smudge: decrypts when an identity file is available" {
  touch "$HOME/.age/key.txt"
  run bash -c 'echo "SECRET=1" | _secrets_git_smudge'
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=1" ]
}

@test "_secrets_git_smudge: falls back to passthrough when decryption fails (wrong/no key)" {
  touch "$HOME/.age/key.txt"
  run bash -c 'echo "BADCIPHER" | _secrets_git_smudge'
  [ "$status" -eq 0 ]
  [ "$output" = "BADCIPHER" ]
}

@test "_secrets_git_smudge: never returns non-zero, even with no age installed at all" {
  unset -f age
  local safe_bin; safe_bin="$(_path_without_age)"
  touch "$HOME/.age/key.txt"
  PATH="$safe_bin" run bash -c 'echo "anything" | _secrets_git_smudge'
  [ "$status" -eq 0 ]
  [ "$output" = "anything" ]
}

@test "_secrets_git_smudge: honors STRUT_AGE_IDENTITY over the default search order" {
  local custom_id="$TEST_TMP/custom.key"
  touch "$custom_id"
  export STRUT_AGE_IDENTITY="$custom_id"
  run bash -c 'echo "SECRET=1" | _secrets_git_smudge'
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=1" ]
}

# ── _secrets_filter_install / uninstall / status ────────────────────────────
# These touch real local git config, so use a real (throwaway) git repo.

_init_git_repo() {
  git init -q "$TEST_TMP" >/dev/null
  git -C "$TEST_TMP" config user.email test@example.com
  git -C "$TEST_TMP" config user.name test
}

@test "cmd_secrets_filter install: fails outside a git repository" {
  run cmd_secrets_filter install
  [ "$status" -ne 0 ]
  [[ "$output" == *"git repository"* ]]
}

@test "cmd_secrets_filter install: fails when age is not installed" {
  _init_git_repo
  unset -f age
  local safe_bin; safe_bin="$(_path_without_age)"
  PATH="$safe_bin" run cmd_secrets_filter install
  [ "$status" -ne 0 ]
  [[ "$output" == *"age"* ]]
}

@test "cmd_secrets_filter install: wires clean/smudge/required in local git config" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  touch "$TEST_TMP/strut"; chmod +x "$TEST_TMP/strut"

  run cmd_secrets_filter install
  [ "$status" -eq 0 ]

  [[ "$(git -C "$TEST_TMP" config filter.strutsecrets.clean)"  == *"secrets-filter clean"*  ]]
  [[ "$(git -C "$TEST_TMP" config filter.strutsecrets.smudge)" == *"secrets-filter smudge"* ]]
  [ "$(git -C "$TEST_TMP" config filter.strutsecrets.required)" = "true" ]
}

@test "cmd_secrets_filter install: appends a .gitattributes rule covering every env by default" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  touch "$TEST_TMP/strut"; chmod +x "$TEST_TMP/strut"

  cmd_secrets_filter install >/dev/null
  [ -f "$TEST_TMP/.gitattributes" ]
  grep -qxF "*.enc.env filter=strutsecrets diff=strutsecrets -text" "$TEST_TMP/.gitattributes"
}

@test "cmd_secrets_filter install: --env scopes .gitattributes to that env only" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  touch "$TEST_TMP/strut"; chmod +x "$TEST_TMP/strut"

  cmd_secrets_filter install --env prod >/dev/null
  grep -qxF ".prod.enc.env filter=strutsecrets diff=strutsecrets -text" "$TEST_TMP/.gitattributes"
  ! grep -qxF "*.enc.env filter=strutsecrets diff=strutsecrets -text" "$TEST_TMP/.gitattributes"
}

@test "cmd_secrets_filter install: running twice does not duplicate the .gitattributes rule" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  touch "$TEST_TMP/strut"; chmod +x "$TEST_TMP/strut"

  cmd_secrets_filter install >/dev/null
  cmd_secrets_filter install >/dev/null
  local count
  count=$(grep -cxF "*.enc.env filter=strutsecrets diff=strutsecrets -text" "$TEST_TMP/.gitattributes")
  [ "$count" -eq 1 ]
}

@test "cmd_secrets_filter status: reports not installed before install" {
  _init_git_repo
  run cmd_secrets_filter status
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "cmd_secrets_filter status: reports installed after install" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  touch "$TEST_TMP/strut"; chmod +x "$TEST_TMP/strut"
  cmd_secrets_filter install >/dev/null

  run cmd_secrets_filter status
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed"* ]]
  [[ "$output" == *"required: true"* ]]
}

@test "cmd_secrets_filter uninstall: removes the git config, install can re-run cleanly after" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  touch "$TEST_TMP/strut"; chmod +x "$TEST_TMP/strut"
  cmd_secrets_filter install >/dev/null

  run cmd_secrets_filter uninstall
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$TEST_TMP" config filter.strutsecrets.clean)" ]

  run cmd_secrets_filter status
  [ "$status" -ne 0 ]
}

@test "cmd_secrets_filter uninstall: idempotent when nothing was installed" {
  _init_git_repo
  run cmd_secrets_filter uninstall
  [ "$status" -eq 0 ]
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

@test "cmd_secrets_filter: no args prints usage" {
  run cmd_secrets_filter
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: strut secrets-filter"* ]]
}

@test "cmd_secrets_filter: unknown subcommand fails with usage" {
  run cmd_secrets_filter bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown secrets-filter subcommand"* ]]
}

# ── End-to-end: clean then smudge round-trips content through a real git add/checkout ──

@test "end-to-end: git add (clean) then checkout (smudge) round-trips plaintext via a real repo" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  cp "$BATS_TEST_DIRNAME/../strut" "$TEST_TMP/strut"
  # Point the copied entrypoint's STRUT_HOME resolution at itself via a
  # same-directory lib/ symlink so `strut secrets-filter clean/smudge` (invoked
  # by git with no other env) can source the real lib modules.
  ln -s "$BATS_TEST_DIRNAME/../lib" "$TEST_TMP/lib"
  ln -s "$BATS_TEST_DIRNAME/../templates" "$TEST_TMP/templates"

  # `age` as a bash FUNCTION (the rest of this file's mock) doesn't reach
  # here: git invokes the clean/smudge filter via its own `sh -c`, a real
  # subprocess boundary that exported functions don't reliably cross (it
  # happens to work on macOS, where /bin/sh is bash, but not on Linux CI
  # where it's dash and has no concept of exported shell functions at
  # all). A real executable on PATH crosses that boundary correctly under
  # any shell.
  local mock_bin="$TEST_TMP/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/age" <<'EOF'
#!/bin/sh
output=""
input=""
while [ $# -gt 0 ]; do
  case "$1" in
    -e|-d) shift ;;
    -o) output="$2"; shift 2 ;;
    -R) shift 2 ;;
    -i) shift 2 ;;
    *) input="$1"; shift ;;
  esac
done
if [ -n "$input" ]; then
  if [ -n "$output" ]; then cp "$input" "$output"; else cat "$input"; fi
else
  cat
fi
EOF
  chmod +x "$mock_bin/age"
  export PATH="$mock_bin:$PATH"

  echo "age1qtest" > "$TEST_TMP/.strut-recipients"
  cmd_secrets_filter install >/dev/null

  cd "$TEST_TMP"
  echo "SECRET=roundtrip" > .prod.enc.env
  git add .prod.enc.env
  git commit -q -m "add secret"

  # What's actually stored should be run through our (identity) fake age —
  # confirms `clean` ran at all, not just that the working tree looks right.
  run git show HEAD:.prod.enc.env
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=roundtrip" ]

  rm .prod.enc.env
  git checkout -- .prod.enc.env
  [ "$(cat .prod.enc.env)" = "SECRET=roundtrip" ]
}

# ── Regression: the filter must actually work in a real strut project ──────
# (strut#178 gap #2) — the shipped filter routed .*.env through
# clean/smudge, but the generated project .gitignore ALSO ignores .*.env,
# so `git add` silently skipped the file (no -f) and clean never ran. This
# test reproduces a real strut-style .gitignore (not the bare repo the test
# above uses) and would FAIL before the .enc.env negation was added.
@test "end-to-end: .enc.env round-trips through a real strut-style .gitignore (strut#178 gap #2)" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  cp "$BATS_TEST_DIRNAME/../strut" "$TEST_TMP/strut"
  ln -s "$BATS_TEST_DIRNAME/../lib" "$TEST_TMP/lib"
  ln -s "$BATS_TEST_DIRNAME/../templates" "$TEST_TMP/templates"

  local mock_bin="$TEST_TMP/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/age" <<'EOF'
#!/bin/sh
output=""
input=""
while [ $# -gt 0 ]; do
  case "$1" in
    -e|-d) shift ;;
    -o) output="$2"; shift 2 ;;
    -R) shift 2 ;;
    -i) shift 2 ;;
    *) input="$1"; shift ;;
  esac
done
if [ -n "$input" ]; then
  if [ -n "$output" ]; then cp "$input" "$output"; else cat "$input"; fi
else
  cat
fi
EOF
  chmod +x "$mock_bin/age"
  export PATH="$mock_bin:$PATH"

  echo "age1qtest" > "$TEST_TMP/.strut-recipients"
  cmd_secrets_filter install >/dev/null

  cd "$TEST_TMP"
  printf '.env\n.env.*\n.*.env\n!.env.template\n!*.env.age\n!*.env.gpg\n!*.enc.env\n!.*.enc.env\n' > .gitignore
  git add .gitignore
  git commit -q -m "add gitignore"

  # A plaintext .prod.env stays ignored — sanity check the fixture is real.
  run git check-ignore .prod.env
  [ "$status" -eq 0 ]

  echo "SECRET=roundtrip" > .prod.enc.env
  git add .prod.enc.env
  run git status --porcelain
  [[ "$output" == *".prod.enc.env"* ]]
  git commit -q -m "add secret"

  run git show HEAD:.prod.enc.env
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=roundtrip" ]

  rm .prod.enc.env
  git checkout -- .prod.enc.env
  [ "$(cat .prod.enc.env)" = "SECRET=roundtrip" ]
}

@test "end-to-end: .enc.env under stacks/<name>/ round-trips through a strut-style .gitignore (strut#178 gap #2)" {
  _init_git_repo
  export STRUT_HOME="$TEST_TMP"
  cp "$BATS_TEST_DIRNAME/../strut" "$TEST_TMP/strut"
  ln -s "$BATS_TEST_DIRNAME/../lib" "$TEST_TMP/lib"
  ln -s "$BATS_TEST_DIRNAME/../templates" "$TEST_TMP/templates"

  local mock_bin="$TEST_TMP/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/age" <<'EOF'
#!/bin/sh
output=""
input=""
while [ $# -gt 0 ]; do
  case "$1" in
    -e|-d) shift ;;
    -o) output="$2"; shift 2 ;;
    -R) shift 2 ;;
    -i) shift 2 ;;
    *) input="$1"; shift ;;
  esac
done
if [ -n "$input" ]; then
  if [ -n "$output" ]; then cp "$input" "$output"; else cat "$input"; fi
else
  cat
fi
EOF
  chmod +x "$mock_bin/age"
  export PATH="$mock_bin:$PATH"

  echo "age1qtest" > "$TEST_TMP/stacks/demo/.strut-recipients"
  cmd_secrets_filter install >/dev/null

  cd "$TEST_TMP"
  printf '.env\n.env.*\n.*.env\n!.env.template\n!*.env.age\n!*.env.gpg\n!*.enc.env\n!.*.enc.env\n' > .gitignore
  git add .gitignore
  git commit -q -m "add gitignore"

  echo "SECRET=roundtrip" > stacks/demo/.prod.enc.env
  git add stacks/demo/.prod.enc.env
  run git status --porcelain
  [[ "$output" == *"stacks/demo/.prod.enc.env"* ]]
  git commit -q -m "add stack secret"

  run git show HEAD:stacks/demo/.prod.enc.env
  [ "$status" -eq 0 ]
  [ "$output" = "SECRET=roundtrip" ]

  rm stacks/demo/.prod.enc.env
  git checkout -- stacks/demo/.prod.enc.env
  [ "$(cat stacks/demo/.prod.enc.env)" = "SECRET=roundtrip" ]
}
