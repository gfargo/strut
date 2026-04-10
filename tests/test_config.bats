#!/usr/bin/env bats
# ==================================================
# tests/test_config.bats — Property tests for lib/config.sh
# ==================================================
# Run:  bats tests/test_config.bats
# Covers: find_project_root, load_strut_config, resolve_strut_home
# Feature: ch-deploy-modularization, Properties 1, 2, 16

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

_load_utils() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
}

_load_config() {
  _load_utils
  source "$CLI_ROOT/lib/config.sh"
}

# ── Helper: generate random alphanumeric string ──────────────────────────────

_rand_str() {
  local len="${1:-8}"
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$len" 2>/dev/null || true
}

# ── Property 1: Config walk-up finds strut.conf from any subdirectory ────────
# Feature: ch-deploy-modularization, Property 1: Config walk-up finds strut.conf from any subdirectory
# Validates: Requirements 1.1

@test "Property 1: Config walk-up finds strut.conf from any subdirectory (100 iterations)" {
  _load_config

  for i in $(seq 1 100); do
    # Generate a random depth between 1 and 5
    local depth=$(( (RANDOM % 5) + 1 ))

    # Build a random nested directory path
    local project_dir="$TEST_TMP/proj_$i"
    local subdir="$project_dir"
    for d in $(seq 1 "$depth"); do
      subdir="$subdir/dir_${d}_$(_rand_str 4)"
    done
    mkdir -p "$subdir"

    # Place strut.conf at the project root
    echo "# test config $i" > "$project_dir/strut.conf"

    # Run find_project_root from the deep subdirectory
    (
      cd "$subdir"
      unset PROJECT_ROOT
      find_project_root
      [ "$PROJECT_ROOT" = "$project_dir" ]
    )
  done
}

# ── Property 1 edge case: returns 1 when no strut.conf exists ────────────────

@test "find_project_root returns 1 when no strut.conf exists" {
  _load_config

  local empty_dir="$TEST_TMP/empty_project"
  mkdir -p "$empty_dir/sub/deep"

  (
    cd "$empty_dir/sub/deep"
    unset PROJECT_ROOT
    run find_project_root
    [ "$status" -eq 1 ]
  )
}

# ── Property 2: Config parsing loads present keys and defaults absent keys ───
# Feature: ch-deploy-modularization, Property 2: Config parsing loads present keys and defaults absent keys
# Validates: Requirements 1.2, 1.4

@test "Property 2: Config parsing loads present keys and defaults absent keys (100 iterations)" {
  _load_config

  local keys=("REGISTRY_TYPE" "REGISTRY_HOST" "DEFAULT_ORG" "DEFAULT_BRANCH" "BANNER_TEXT" "REVERSE_PROXY")
  local defaults=("none" "" "" "main" "strut" "nginx")
  local valid_proxies=("nginx" "caddy")

  for i in $(seq 1 100); do
    local project_dir="$TEST_TMP/parse_$i"
    mkdir -p "$project_dir"
    local conf="$project_dir/strut.conf"
    > "$conf"

    # Track which keys are present and their values
    local -a present_keys=()
    local -a present_vals=()
    local -a absent_keys=()
    local -a absent_defaults=()

    for idx in "${!keys[@]}"; do
      if (( RANDOM % 2 )); then
        local val
        if [ "${keys[$idx]}" = "REVERSE_PROXY" ]; then
          # Pick a valid proxy value when present
          val="${valid_proxies[$((RANDOM % 2))]}"
        else
          val="val_${RANDOM}_$(_rand_str 4)"
        fi
        echo "${keys[$idx]}=$val" >> "$conf"
        present_keys+=("${keys[$idx]}")
        present_vals+=("$val")
      else
        absent_keys+=("${keys[$idx]}")
        absent_defaults+=("${defaults[$idx]}")
      fi
    done

    # Source config in a subshell to avoid polluting state
    (
      # Clear all config vars
      unset REGISTRY_TYPE REGISTRY_HOST DEFAULT_ORG DEFAULT_BRANCH BANNER_TEXT REVERSE_PROXY PROJECT_ROOT

      PROJECT_ROOT="$project_dir"
      export PROJECT_ROOT
      load_strut_config

      # Verify present keys have their specified values
      for idx in "${!present_keys[@]}"; do
        local actual="${!present_keys[$idx]}"
        [ "$actual" = "${present_vals[$idx]}" ]
      done

      # Verify absent keys have their defaults
      for idx in "${!absent_keys[@]}"; do
        local actual="${!absent_keys[$idx]}"
        [ "$actual" = "${absent_defaults[$idx]}" ]
      done
    )
  done
}

# ── Property 2 edge case: all defaults when strut.conf is empty ──────────────

@test "load_strut_config applies all defaults when strut.conf is empty" {
  _load_config

  local project_dir="$TEST_TMP/empty_conf"
  mkdir -p "$project_dir"
  > "$project_dir/strut.conf"

  (
    unset REGISTRY_TYPE REGISTRY_HOST DEFAULT_ORG DEFAULT_BRANCH BANNER_TEXT REVERSE_PROXY
    PROJECT_ROOT="$project_dir"
    export PROJECT_ROOT
    load_strut_config

    [ "$REGISTRY_TYPE" = "none" ]
    [ "$REGISTRY_HOST" = "" ]
    [ "$DEFAULT_ORG" = "" ]
    [ "$DEFAULT_BRANCH" = "main" ]
    [ "$BANNER_TEXT" = "strut" ]
    [ "$REVERSE_PROXY" = "nginx" ]
  )
}

# ── Property 2 edge case: all keys present ───────────────────────────────────

@test "load_strut_config loads all keys when all are present" {
  _load_config

  local project_dir="$TEST_TMP/full_conf"
  mkdir -p "$project_dir"
  cat > "$project_dir/strut.conf" <<'EOF'
REGISTRY_TYPE=ghcr
REGISTRY_HOST=ghcr.io
DEFAULT_ORG=my-org
DEFAULT_BRANCH=develop
BANNER_TEXT=my-project
REVERSE_PROXY=caddy
EOF

  (
    unset REGISTRY_TYPE REGISTRY_HOST DEFAULT_ORG DEFAULT_BRANCH BANNER_TEXT REVERSE_PROXY
    PROJECT_ROOT="$project_dir"
    export PROJECT_ROOT
    load_strut_config

    [ "$REGISTRY_TYPE" = "ghcr" ]
    [ "$REGISTRY_HOST" = "ghcr.io" ]
    [ "$DEFAULT_ORG" = "my-org" ]
    [ "$DEFAULT_BRANCH" = "develop" ]
    [ "$BANNER_TEXT" = "my-project" ]
    [ "$REVERSE_PROXY" = "caddy" ]
  )
}

# ── Property 16: Symlink resolution finds Strut_Home regardless of symlink location
# Feature: ch-deploy-modularization, Property 16: Symlink resolution finds Strut_Home regardless of symlink location
# Validates: Requirements 14.3

@test "Property 16: Symlink resolution finds Strut_Home regardless of symlink location (100 iterations)" {
  _load_config

  # Create a "real" script location
  local real_dir="$TEST_TMP/real_strut_home"
  mkdir -p "$real_dir"
  echo '#!/usr/bin/env bash' > "$real_dir/strut"
  chmod +x "$real_dir/strut"

  for i in $(seq 1 100); do
    # Generate a random symlink location
    local depth=$(( (RANDOM % 4) + 1 ))
    local link_dir="$TEST_TMP/link_$i"
    for d in $(seq 1 "$depth"); do
      link_dir="$link_dir/d_$(_rand_str 3)"
    done
    mkdir -p "$link_dir"

    local link_path="$link_dir/strut"
    ln -sf "$real_dir/strut" "$link_path"

    # Resolve and verify
    (
      unset STRUT_HOME
      resolve_strut_home "$link_path"
      [ "$STRUT_HOME" = "$real_dir" ]
    )
  done
}

# ── Property 16 edge case: non-symlink resolves to its own directory ─────────

@test "resolve_strut_home resolves non-symlink to its own directory" {
  _load_config

  local script_dir="$TEST_TMP/direct_home"
  mkdir -p "$script_dir"
  echo '#!/usr/bin/env bash' > "$script_dir/strut"
  chmod +x "$script_dir/strut"

  (
    unset STRUT_HOME
    resolve_strut_home "$script_dir/strut"
    [ "$STRUT_HOME" = "$script_dir" ]
  )
}

# ── Property 16 edge case: chained symlinks ──────────────────────────────────

@test "resolve_strut_home follows chained symlinks" {
  _load_config

  local real_dir="$TEST_TMP/chain_real"
  mkdir -p "$real_dir"
  echo '#!/usr/bin/env bash' > "$real_dir/strut"
  chmod +x "$real_dir/strut"

  # Create a chain: link3 -> link2 -> link1 -> real
  local link_dir="$TEST_TMP/chain_links"
  mkdir -p "$link_dir"
  ln -sf "$real_dir/strut" "$link_dir/link1"
  ln -sf "$link_dir/link1" "$link_dir/link2"
  ln -sf "$link_dir/link2" "$link_dir/link3"

  (
    unset STRUT_HOME
    resolve_strut_home "$link_dir/link3"
    [ "$STRUT_HOME" = "$real_dir" ]
  )
}
