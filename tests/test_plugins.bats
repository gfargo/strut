#!/usr/bin/env bats
# ==================================================
# tests/test_plugins.bats — Project-local plugin discovery & dispatch
# ==================================================
# Run:  bats tests/test_plugins.bats
# Covers: plugins_discover, plugins_has, plugins_run, plugins_help,
# plugins_list_text/json, end-to-end dispatch through the strut entrypoint.

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLI_ROOT
  CLI="$CLI_ROOT/strut"
  TEST_TMP="$(mktemp -d)"
  export PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$PROJECT_ROOT/.strut/plugins"
}

teardown() {
  rm -rf "$TEST_TMP"
  # Remove any test stack dropped under the strut repo
  rm -rf "$CLI_ROOT/stacks/test-plugin-stack"
  unset PROJECT_ROOT
}

_load_plugins() {
  source "$CLI_ROOT/lib/utils.sh"
  fail() { echo "$1" >&2; return 1; }
  source "$CLI_ROOT/lib/output.sh"
  source "$CLI_ROOT/lib/plugins.sh"
}

_make_plugin() {
  local name="$1" body="$2"
  cat > "$PROJECT_ROOT/.strut/plugins/cmd_${name}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$body
EOF
}

# ── Discovery ─────────────────────────────────────────────────────────────────

@test "plugins_discover: picks up cmd_*.sh files" {
  _load_plugins
  _make_plugin "foo" '
plugin_help() { echo "foo desc"; }
plugin_main() { echo "foo main: $@"; }
'
  _make_plugin "bar" '
plugin_help() { echo "bar desc"; }
plugin_main() { echo "bar main"; }
'
  plugins_discover
  plugins_has "foo"
  plugins_has "bar"
}

@test "plugins_discover: ignores non-cmd files" {
  _load_plugins
  _make_plugin "real" 'plugin_main() { :; }'
  cat > "$PROJECT_ROOT/.strut/plugins/helper.sh" <<'EOF'
# not a plugin — should be ignored
echo "should not run"
EOF
  plugins_discover
  plugins_has "real"
  run plugins_has "helper"
  [ "$status" -ne 0 ]
}

@test "plugins_discover: no-op when plugins dir missing" {
  _load_plugins
  rm -rf "$PROJECT_ROOT/.strut"
  run plugins_discover
  [ "$status" -eq 0 ]
  run plugins_has "anything"
  [ "$status" -ne 0 ]
}

@test "plugins_file_for: returns path for known plugin, fails for unknown" {
  _load_plugins
  _make_plugin "ship" 'plugin_main() { :; }'
  plugins_discover
  run plugins_file_for "ship"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_ship.sh" ]]
  run plugins_file_for "missing"
  [ "$status" -ne 0 ]
}

# ── plugins_run ───────────────────────────────────────────────────────────────

@test "plugins_run: invokes plugin_main with forwarded args" {
  _load_plugins
  _make_plugin "echoer" '
plugin_main() { echo "got: $*"; }
'
  plugins_discover
  run plugins_run "echoer" a b c
  [ "$status" -eq 0 ]
  [[ "$output" == "got: a b c" ]]
}

@test "plugins_run: errors when plugin_main missing" {
  _load_plugins
  _make_plugin "noop" '
plugin_help() { echo "no main here"; }
'
  plugins_discover
  run plugins_run "noop"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin_main"* ]]
}

@test "plugins_run: subshell isolation — plugin exit does not kill parent" {
  _load_plugins
  _make_plugin "crasher" '
plugin_main() { exit 7; }
'
  plugins_discover
  # The parent shell keeps running even though plugin_main exited.
  run plugins_run "crasher"
  [ "$status" -eq 7 ]
  # Subsequent calls still work — proves we did not kill the parent.
  run plugins_has "crasher"
  [ "$status" -eq 0 ]
}

# ── plugins_help ──────────────────────────────────────────────────────────────

@test "plugins_help: prints plugin_help output" {
  _load_plugins
  _make_plugin "docd" '
plugin_help() { echo "Documented plugin"; }
plugin_main() { :; }
'
  plugins_discover
  run plugins_help "docd"
  [ "$status" -eq 0 ]
  [[ "$output" == "Documented plugin" ]]
}

@test "plugins_help: empty output when plugin omits plugin_help" {
  _load_plugins
  _make_plugin "terse" '
plugin_main() { :; }
'
  plugins_discover
  run plugins_help "terse"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── plugins_list ──────────────────────────────────────────────────────────────

@test "plugins_list_text: renders discovered plugins" {
  _load_plugins
  _make_plugin "alpha" '
plugin_help() { echo "first plugin"; }
plugin_main() { :; }
'
  _make_plugin "beta" '
plugin_help() { echo "second plugin"; }
plugin_main() { :; }
'
  plugins_discover
  run plugins_list_text
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"first plugin"* ]]
  [[ "$output" == *"beta"* ]]
  [[ "$output" == *"second plugin"* ]]
}

@test "plugins_list_text: empty-state message when no plugins" {
  _load_plugins
  plugins_discover
  run plugins_list_text
  [ "$status" -eq 0 ]
  [[ "$output" == *"No plugins found"* ]]
}

@test "plugins_list_json: emits valid JSON with plugin metadata" {
  _load_plugins
  _make_plugin "jsonplug" '
plugin_help() { echo "json desc"; }
plugin_main() { :; }
'
  plugins_discover
  export OUTPUT_MODE=json
  run plugins_list_json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"plugins\""* ]]
  [[ "$output" == *"\"name\":\"jsonplug\""* ]]
  [[ "$output" == *"\"description\":\"json desc\""* ]]
}

# ── Entrypoint dispatch (end-to-end) ──────────────────────────────────────────

@test "strut <plugin>: top-level dispatch runs plugin_main" {
  _make_plugin "greet" '
plugin_help() { echo "greets"; }
plugin_main() { echo "hello from plugin: $*"; }
'
  # Invoke from PROJECT_ROOT so find_project_root picks it up
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
BANNER_TEXT="test"
EOF
  cd "$PROJECT_ROOT"
  run bash "$CLI" greet world
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from plugin: world"* ]]
}

@test "strut <stack> <plugin>: stack-level dispatch passes stack + env" {
  mkdir -p "$CLI_ROOT/stacks/test-plugin-stack"
  touch "$CLI_ROOT/stacks/test-plugin-stack/docker-compose.yml"
  _make_plugin "ship" '
plugin_help() { echo "ship it"; }
plugin_main() {
  local stack="$1" env_name="$2"; shift 2
  echo "stack=$stack env=$env_name rest=$*"
}
'
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
BANNER_TEXT="test"
EOF
  cd "$PROJECT_ROOT"
  run bash "$CLI" test-plugin-stack ship --env prod extra
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack=test-plugin-stack"* ]]
  [[ "$output" == *"env=prod"* ]]
  [[ "$output" == *"rest=extra"* ]]
}

@test "strut <plugin>: core command shadows plugin of same name" {
  _make_plugin "list" '
plugin_main() { echo "plugin list ran"; }
'
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
BANNER_TEXT="test"
EOF
  cd "$PROJECT_ROOT"
  run bash "$CLI" list
  [ "$status" -eq 0 ]
  # Core `list` renders the stacks header. Plugin must not have run.
  [[ "$output" == *"Available stacks"* ]]
  [[ "$output" != *"plugin list ran"* ]]
}

@test "strut <stack> <plugin>: core stack command shadows plugin of same name" {
  mkdir -p "$CLI_ROOT/stacks/test-plugin-stack"
  touch "$CLI_ROOT/stacks/test-plugin-stack/docker-compose.yml"
  _make_plugin "deploy" '
plugin_main() { echo "plugin deploy ran"; }
'
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
BANNER_TEXT="test"
EOF
  cd "$PROJECT_ROOT"
  # `deploy` is a core command — should invoke core cmd_deploy (which will
  # fail fast because test-plugin-stack has no .env), never the plugin.
  run bash "$CLI" test-plugin-stack deploy
  [[ "$output" != *"plugin deploy ran"* ]]
}

@test "strut list plugins: lists discovered plugins" {
  _make_plugin "telemetry" '
plugin_help() { echo "ship telemetry"; }
plugin_main() { :; }
'
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
BANNER_TEXT="test"
EOF
  cd "$PROJECT_ROOT"
  run bash "$CLI" list plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"telemetry"* ]]
  [[ "$output" == *"ship telemetry"* ]]
}

@test "strut list plugins --json: emits JSON" {
  _make_plugin "jsonplug" '
plugin_help() { echo "json ok"; }
plugin_main() { :; }
'
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
BANNER_TEXT="test"
EOF
  cd "$PROJECT_ROOT"
  run bash "$CLI" list plugins --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"plugins\""* ]]
  [[ "$output" == *"\"name\":\"jsonplug\""* ]]
}

@test "strut help <plugin>: runs plugin_help" {
  _make_plugin "explained" '
plugin_help() { echo "this is what I do"; }
plugin_main() { :; }
'
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
BANNER_TEXT="test"
EOF
  cd "$PROJECT_ROOT"
  run bash "$CLI" help explained
  [ "$status" -eq 0 ]
  [[ "$output" == *"this is what I do"* ]]
}

@test "strut <plugin>: re-entrant — plugin can invoke strut itself" {
  _make_plugin "relay" '
plugin_main() { "'"$CLI"'" --version; }
'
  cat > "$PROJECT_ROOT/strut.conf" <<'EOF'
BANNER_TEXT="test"
EOF
  cd "$PROJECT_ROOT"
  run bash "$CLI" relay
  [ "$status" -eq 0 ]
  # --version prints the VERSION file contents
  [ -n "$output" ]
}
