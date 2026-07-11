#!/usr/bin/env bats
# ==================================================
# tests/test_adopt.bats — Tests for lib/cmd_adopt.sh
# ==================================================
# Run:  bats tests/test_adopt.bats
# Covers: _usage_adopt, cmd_adopt arg parsing/dry-run, _adopt_discover,
#         _adopt_verify_compose, _adopt_detect_data, _adopt_mark,
#         _adopt_pull_env — all SSH-stubbed, no network/VPS needed.

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  source "$CLI_ROOT/lib/output.sh"
  fail() { echo "FAIL: $1" >&2; return 1; }
  ok()   { echo "OK: $*"; }
  warn() { echo "WARN: $*" >&2; }
  log()  { echo "LOG: $*"; }
  error() { echo "ERROR: $*" >&2; }
  print_banner() { echo "BANNER: $*"; }
  run_cmd() { echo "RUN: $*"; }
  export -f fail ok warn log error print_banner run_cmd

  source "$CLI_ROOT/lib/diff.sh"

  build_ssh_opts() { echo "-o StrictHostKeyChecking=no"; }
  export -f build_ssh_opts

  git() {
    case "$1" in
      remote) echo "https://github.com/gfargo/strut.git" ;;
      *) command git "$@" ;;
    esac
  }
  export -f git

  _secrets_lock() { echo "SECRETS_LOCK_CALLED"; return 0; }
  export -f _secrets_lock

  setup_strut_repo() { echo "SETUP_STRUT_REPO: $*"; return 0; }
  export -f setup_strut_repo

  fleet_sync() { echo "FLEET_SYNC: $*"; return 0; }
  export -f fleet_sync

  source "$CLI_ROOT/lib/cmd_adopt.sh"

  export CMD_STACK="myapp"
  export CMD_STACK_DIR="$TEST_TMP/stacks/myapp"
  mkdir -p "$CMD_STACK_DIR"
  cat > "$CMD_STACK_DIR/docker-compose.yml" <<'EOF'
services:
  web:
    image: nginx
EOF
  export CMD_ENV_NAME="prod"
  export DRY_RUN=false
}

teardown() { common_teardown; }

# ── Usage ─────────────────────────────────────────────────────────────────────

@test "_usage_adopt: prints usage information" {
  run _usage_adopt
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--host"* ]]
  [[ "$output" == *"--user"* ]]
  [[ "$output" == *"--key"* ]]
  [[ "$output" == *"--port"* ]]
  [[ "$output" == *"--env"* ]]
  [[ "$output" == *"--remote-dir"* ]]
  [[ "$output" == *"--remote-env-file"* ]]
  [[ "$output" == *"--repo"* ]]
  [[ "$output" == *"--branch"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--force"* ]]
}

@test "_usage_adopt: includes examples" {
  run _usage_adopt
  [ "$status" -eq 0 ]
  [[ "$output" == *"Examples:"* ]]
  [[ "$output" == *"adopt"* ]]
}

@test "_usage_adopt: describes what it does" {
  run _usage_adopt
  [ "$status" -eq 0 ]
  [[ "$output" == *"What this does:"* ]]
  [[ "$output" == *"Discovers"* ]]
  [[ "$output" == *"fresh"* ]]
}

# ── Arg parsing / early errors ──────────────────────────────────────────────

@test "cmd_adopt: fails without stack context" {
  unset CMD_STACK

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_adopt --host 10.0.0.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"strut <stack> adopt"* ]]
}

@test "cmd_adopt: fails without --host" {
  unset VPS_HOST

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_adopt
  [ "$status" -ne 0 ]
  [[ "$output" == *"--host"* ]]
}

@test "cmd_adopt: fails without a committed compose file" {
  rm -f "$CMD_STACK_DIR/docker-compose.yml"

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_adopt --host 10.0.0.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"No committed compose file found"* ]]
}

@test "cmd_adopt: fails when repo URL cannot be detected and --repo is not given" {
  git() { return 1; }
  export -f git

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_adopt --host 10.0.0.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--repo"* ]]
}

# ── cmd_adopt dry-run flow (--remote-dir skips discovery) ──────────────────

@test "cmd_adopt: dry-run with --remote-dir shows execution plan and makes no changes" {
  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"echo ok"*) echo "ok" ;;
      *"docker ps -q"*) echo "" ;;
      *"cat '/opt/myapp/docker-compose.yml'"*) cat "$CMD_STACK_DIR/docker-compose.yml" ;;
      *) echo "" ;;
    esac
  }
  export -f ssh

  run cmd_adopt --host 10.0.0.1 --user deploy --remote-dir /opt/myapp --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"No changes made"* ]]
}

@test "cmd_adopt: dry-run reports compose match" {
  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"echo ok"*) echo "ok" ;;
      *"docker ps -q"*) echo "" ;;
      *"cat '/opt/myapp/docker-compose.yml'"*) cat "$CMD_STACK_DIR/docker-compose.yml" ;;
      *) echo "" ;;
    esac
  }
  export -f ssh

  run cmd_adopt --host 10.0.0.1 --user deploy --remote-dir /opt/myapp --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches what's running"* ]]
}

@test "cmd_adopt: dry-run aborts on compose mismatch without --force" {
  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"echo ok"*) echo "ok" ;;
      *"docker ps -q"*) echo "" ;;
      *"cat '/opt/myapp/docker-compose.yml'"*) printf 'services:\n  web:\n    image: nginx:different-tag\n' ;;
      *) echo "" ;;
    esac
  }
  export -f ssh

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run cmd_adopt --host 10.0.0.1 --user deploy --remote-dir /opt/myapp --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"doesn't match what's running"* ]]
}

@test "cmd_adopt: dry-run proceeds past compose mismatch with --force" {
  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"echo ok"*) echo "ok" ;;
      *"docker ps -q"*) echo "" ;;
      *"cat '/opt/myapp/docker-compose.yml'"*) printf 'services:\n  web:\n    image: nginx:different-tag\n' ;;
      *) echo "" ;;
    esac
  }
  export -f ssh

  run cmd_adopt --host 10.0.0.1 --user deploy --remote-dir /opt/myapp --dry-run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Proceeding despite compose mismatch"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "cmd_adopt: dry-run reports a live data directory found inside the checkout" {
  cat > "$CMD_STACK_DIR/docker-compose.yml" <<'EOF'
services:
  db:
    image: postgres
    volumes:
      - ./data/pg:/var/lib/postgresql/data
EOF

  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"echo ok"*) echo "ok" ;;
      *"docker ps -q"*) echo "" ;;
      *"cat '/opt/myapp/docker-compose.yml'"*) cat "$CMD_STACK_DIR/docker-compose.yml" ;;
      *"test -d '/opt/myapp/data/pg'"*) return 0 ;;
      *) echo "" ;;
    esac
  }
  export -f ssh

  run cmd_adopt --host 10.0.0.1 --user deploy --remote-dir /opt/myapp --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Data directory lives inside the checkout: /opt/myapp/data/pg"* ]]
}

@test "cmd_adopt: dry-run reports clean when no data directories are found" {
  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"echo ok"*) echo "ok" ;;
      *"docker ps -q"*) echo "" ;;
      *"cat '/opt/myapp/docker-compose.yml'"*) cat "$CMD_STACK_DIR/docker-compose.yml" ;;
      *) echo "" ;;
    esac
  }
  export -f ssh

  run cmd_adopt --host 10.0.0.1 --user deploy --remote-dir /opt/myapp --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No bind-mount volumes found"* ]]
}

# ── _adopt_discover ──────────────────────────────────────────────────────────

@test "_adopt_discover: finds project matching bare stack name" {
  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"filter 'label=com.docker.compose.project=myapp'"*) echo "abc123" ;;
      *"docker inspect 'abc123'"*) echo "/opt/myapp" ;;
      *) echo "" ;;
    esac
  }
  export -f ssh

  if _adopt_discover "-o x" "ubuntu" "host.example" "myapp" "prod"; then st=0; else st=1; fi
  [ "$st" -eq 0 ]
  [ "$ADOPT_DISCOVERED_WORKING_DIR" = "/opt/myapp" ]
  [ "$ADOPT_DISCOVERED_PROJECT_NAME" = "myapp" ]
}

@test "_adopt_discover: falls back to stack-env naming convention" {
  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"filter 'label=com.docker.compose.project=myapp'"*) echo "" ;;
      *"filter 'label=com.docker.compose.project=myapp-prod'"*) echo "def456" ;;
      *"docker inspect 'def456'"*) echo "/opt/myapp-prod" ;;
      *) echo "" ;;
    esac
  }
  export -f ssh

  if _adopt_discover "-o x" "ubuntu" "host.example" "myapp" "prod"; then st=0; else st=1; fi
  [ "$st" -eq 0 ]
  [ "$ADOPT_DISCOVERED_PROJECT_NAME" = "myapp-prod" ]
  [ "$ADOPT_DISCOVERED_WORKING_DIR" = "/opt/myapp-prod" ]
}

@test "_adopt_discover: returns 1 when no matching project is running" {
  ssh() { echo ""; }
  export -f ssh

  if _adopt_discover "-o x" "ubuntu" "host.example" "myapp" "prod"; then st=0; else st=1; fi
  [ "$st" -eq 1 ]
}

# ── _adopt_verify_compose ────────────────────────────────────────────────────

@test "_adopt_verify_compose: returns 0 when remote compose matches local" {
  ssh() { cat "$CMD_STACK_DIR/docker-compose.yml"; }
  export -f ssh

  run _adopt_verify_compose "-o x" "ubuntu" "host.example" "/opt/myapp/docker-compose.yml" "$CMD_STACK_DIR/docker-compose.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches what's running"* ]]
}

@test "_adopt_verify_compose: returns 1 and prints diff when compose differs" {
  ssh() { printf 'services:\n  web:\n    image: nginx:other\n'; }
  export -f ssh

  run _adopt_verify_compose "-o x" "ubuntu" "host.example" "/opt/myapp/docker-compose.yml" "$CMD_STACK_DIR/docker-compose.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs from what's actually running"* ]]
}

@test "_adopt_verify_compose: warns and returns 0 when remote file is unreadable" {
  ssh() { echo ""; }
  export -f ssh

  run _adopt_verify_compose "-o x" "ubuntu" "host.example" "/opt/myapp/docker-compose.yml" "$CMD_STACK_DIR/docker-compose.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not read"* ]]
}

# ── _adopt_detect_data ───────────────────────────────────────────────────────

@test "_adopt_detect_data: reports a bind-mount data directory that exists on remote" {
  local compose="$TEST_TMP/data-compose.yml"
  cat > "$compose" <<'EOF'
services:
  db:
    image: postgres
    volumes:
      - ./data/pg:/var/lib/postgresql/data
EOF

  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"test -d '/opt/myapp/data/pg'"*) return 0 ;;
      *) return 1 ;;
    esac
  }
  export -f ssh

  run _adopt_detect_data "-o x" "ubuntu" "host.example" "/opt/myapp" "$compose" "myapp" "/home/ubuntu/strut"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Data directory lives inside the checkout: /opt/myapp/data/pg"* ]]
  [[ "$output" == *"/home/ubuntu/strut/stacks/myapp/data/pg"* ]]
}

@test "_adopt_detect_data: skips named volumes" {
  local compose="$TEST_TMP/named-vol-compose.yml"
  cat > "$compose" <<'EOF'
services:
  db:
    image: postgres
    volumes:
      - pgdata:/var/lib/postgresql/data
volumes:
  pgdata:
EOF

  ssh() { return 0; }
  export -f ssh

  run _adopt_detect_data "-o x" "ubuntu" "host.example" "/opt/myapp" "$compose" "myapp" "/home/ubuntu/strut"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No bind-mount volumes found"* ]] || [[ "$output" != *"Data directory lives inside"* ]]
}

@test "_adopt_detect_data: reports clean when the compose file has no volumes" {
  run _adopt_detect_data "-o x" "ubuntu" "host.example" "/opt/myapp" "$CMD_STACK_DIR/docker-compose.yml" "myapp" "/home/ubuntu/strut"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No bind-mount volumes found"* ]]
}

@test "_adopt_detect_data: flags a bind mount whose var has no default" {
  local compose="$TEST_TMP/var-compose.yml"
  cat > "$compose" <<'EOF'
services:
  db:
    image: postgres
    volumes:
      - ${DATA_DIR}:/var/lib/postgresql/data
EOF

  ssh() { return 0; }
  export -f ssh

  run _adopt_detect_data "-o x" "ubuntu" "host.example" "/opt/myapp" "$compose" "myapp" "/home/ubuntu/strut"
  [ "$status" -eq 0 ]
  [[ "$output" == *"depends on an env var with no default"* ]]
}

# ── _adopt_mark ───────────────────────────────────────────────────────────────

@test "_adopt_mark: writes .strut-adopted with expected fields" {
  run _adopt_mark "$CMD_STACK_DIR" "host.example" "myapp" "/opt/myapp"
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.strut-adopted" ]

  run cat "$CMD_STACK_DIR/.strut-adopted"
  [[ "$output" == *"source_host=host.example"* ]]
  [[ "$output" == *"source_project_name=myapp"* ]]
  [[ "$output" == *"source_working_dir=/opt/myapp"* ]]
  [[ "$output" == *"adopted_at="* ]]
}

# ── _adopt_pull_env ───────────────────────────────────────────────────────────

@test "_adopt_pull_env: refuses to overwrite an existing local env file without --force" {
  echo "EXISTING=1" > "$CMD_STACK_DIR/.prod.env"

  fail() { echo "FAIL: $1" >&2; exit 1; }
  export -f fail

  run _adopt_pull_env "-o x" "ubuntu" "host.example" "/opt/myapp/.env" "$CMD_STACK_DIR" "prod" \
    "host.example" "ubuntu" "22" "" "/home/ubuntu/strut" "false"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "_adopt_pull_env: writes merged connection fields and remote env content" {
  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"test -f '/opt/myapp/.env'"*) return 0 ;;
      *"cat '/opt/myapp/.env'"*) echo "APP_SECRET=xyz" ;;
      *) return 0 ;;
    esac
  }
  export -f ssh

  run _adopt_pull_env "-o x" "ubuntu" "host.example" "/opt/myapp/.env" "$CMD_STACK_DIR" "prod" \
    "host.example" "deploy" "2222" "/home/user/.ssh/id_rsa" "/home/deploy/strut" "false"
  [ "$status" -eq 0 ]
  [ -f "$CMD_STACK_DIR/.prod.env" ]

  run cat "$CMD_STACK_DIR/.prod.env"
  [[ "$output" == *"VPS_HOST=host.example"* ]]
  [[ "$output" == *"VPS_USER=deploy"* ]]
  [[ "$output" == *"VPS_PORT=2222"* ]]
  [[ "$output" == *"VPS_SSH_KEY=/home/user/.ssh/id_rsa"* ]]
  [[ "$output" == *"VPS_DEPLOY_DIR=/home/deploy/strut"* ]]
  [[ "$output" == *"APP_SECRET=xyz"* ]]
}

@test "_adopt_pull_env: overwrites existing local env file with --force" {
  echo "EXISTING=1" > "$CMD_STACK_DIR/.prod.env"

  ssh() {
    local cmd="$*"
    case "$cmd" in
      *"test -f '/opt/myapp/.env'"*) return 0 ;;
      *"cat '/opt/myapp/.env'"*) echo "APP_SECRET=xyz" ;;
      *) return 0 ;;
    esac
  }
  export -f ssh

  run _adopt_pull_env "-o x" "ubuntu" "host.example" "/opt/myapp/.env" "$CMD_STACK_DIR" "prod" \
    "host.example" "deploy" "22" "" "/home/deploy/strut" "true"
  [ "$status" -eq 0 ]

  run cat "$CMD_STACK_DIR/.prod.env"
  [[ "$output" != *"EXISTING=1"* ]]
  [[ "$output" == *"APP_SECRET=xyz"* ]]
}
