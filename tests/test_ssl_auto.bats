#!/usr/bin/env bats
# ==================================================
# tests/test_ssl_auto.bats — Tests for lib/ssl/auto.sh (strut#395)
# ==================================================
# `_ssl_detect_domains` used to grab the line AFTER "strut.domain" (grep
# -A1), which only worked for a block-scalar rendering `docker compose
# config` doesn't actually produce — the real (inline) rendering
# `strut.domain: example.com` made it capture an unrelated following line
# instead. `_ssl_provision_one`'s --webroot certbot attempt was also
# missing -d/--email/--non-interactive/--agree-tos, so it could never
# actually succeed and silently always fell through to --standalone.
#
# `ssh` is stubbed to actually run the remote script LOCALLY via `bash -c`
# (the last positional arg is always the remote command string) — this
# exercises the real grep/sed pipeline against realistic `docker compose
# config` output instead of just asserting on the ssh call's raw text.
#
# Run:  bats tests/test_ssl_auto.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/test_helper/common.bash"
  load_utils

  fail()  { echo "FAIL: $1" >&2; return 1; }
  ok()    { echo "OK: $*"; }
  warn()  { echo "WARN: $*" >&2; }
  log()   { echo "LOG: $*"; }
  export -f fail ok warn log

  source "$CLI_ROOT/lib/ssl/auto.sh"

  # Runs the "remote" script locally — the last positional arg is always
  # the command string passed to `ssh $opts user@host "<script>"`.
  ssh() { local cmd="${*: -1}"; bash -c "$cmd"; }
  export -f ssh
}

teardown() { common_teardown; }

# ── _ssl_detect_domains: compose-label parsing (the core strut#395 bug) ────

@test "_ssl_detect_domains: extracts the domain from an inline YAML label rendering" {
  docker() {
    if [ "$1" = "compose" ]; then
      cat <<'EOF'
services:
  web:
    image: nginx:alpine
    labels:
      strut.domain: example.com
      other.label: something-unrelated
EOF
    fi
  }
  export -f docker

  run _ssl_detect_domains "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "_ssl_detect_domains: does NOT mangle the value into the following unrelated line (regression)" {
  docker() {
    if [ "$1" = "compose" ]; then
      cat <<'EOF'
services:
  web:
    labels:
      strut.domain: correct.example.com
      other.label: should-not-appear
EOF
    fi
  }
  export -f docker

  run _ssl_detect_domains "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"correct.example.com"* ]]
  [[ "$output" != *"should-not-appear"* ]]
  [[ "$output" != *"other.label"* ]]
}

@test "_ssl_detect_domains: extracts the domain from list-form quoted labels" {
  docker() {
    if [ "$1" = "compose" ]; then
      cat <<'EOF'
services:
  api:
    labels:
      - "strut.domain=api.example.com"
      - "other=stuff"
EOF
    fi
  }
  export -f docker

  run _ssl_detect_domains "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ "$output" = "api.example.com" ]
}

@test "_ssl_detect_domains: extracts the domain from JSON-format labels (--format json)" {
  docker() {
    if [ "$1" = "compose" ]; then
      cat <<'EOF'
{
  "services": {
    "web": { "labels": { "strut.domain": "json.example.com" } }
  }
}
EOF
    fi
  }
  export -f docker

  run _ssl_detect_domains "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ "$output" = "json.example.com" ]
}

@test "_ssl_detect_domains: multiple services, multiple domains, deduplicated and sorted" {
  docker() {
    if [ "$1" = "compose" ]; then
      cat <<'EOF'
services:
  web:
    labels:
      strut.domain: b.example.com
  api:
    labels:
      strut.domain: a.example.com
  cache:
    labels:
      strut.domain: b.example.com
EOF
    fi
  }
  export -f docker

  run _ssl_detect_domains "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a.example.com\nb.example.com')" ]
}

@test "_ssl_detect_domains: falls back to DOMAIN/DOMAINS/VIRTUAL_HOST env vars when no label present" {
  docker() { :; }
  export -f docker
  export DOMAIN="env.example.com"

  run _ssl_detect_domains "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"env.example.com"* ]]
}

# ── ssl_auto_provision: end-to-end gating ───────────────────────────────────

@test "ssl_auto_provision: no-op when AUTO_SSL=false" {
  export AUTO_SSL=false
  _ssl_provision_one() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f _ssl_provision_one

  run ssl_auto_provision "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

@test "ssl_auto_provision: no-op when no SSL_EMAIL configured" {
  docker() {
    [ "$1" = "compose" ] && echo 'services: {web: {labels: {strut.domain: example.com}}}'
  }
  export -f docker
  unset SSL_EMAIL
  _ssl_provision_one() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f _ssl_provision_one

  run ssl_auto_provision "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

@test "ssl_auto_provision: detected domain is provisioned when SSL_EMAIL is set" {
  docker() {
    if [ "$1" = "compose" ]; then
      echo "services:"; echo "  web:"; echo "    labels:"; echo "      strut.domain: example.com"
    fi
  }
  export -f docker
  export SSL_EMAIL="ops@example.com"
  _ssl_provision_one() { echo "PROVISIONED domain=$1 email=$2"; }
  export -f _ssl_provision_one

  run ssl_auto_provision "demo" "" "" "user" "host" "$TEST_TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROVISIONED domain=example.com email=ops@example.com"* ]]
}

# ── _ssl_provision_one: certbot flags (strut#395) ───────────────────────────

@test "_ssl_provision_one: the --webroot attempt includes -d, --email, --non-interactive, --agree-tos" {
  docker() { :; }
  export -f docker
  # Certificate doesn't exist yet, DNS resolves correctly.
  openssl() { :; }
  curl() { echo "1.2.3.4"; }
  dig() { echo "1.2.3.4"; }
  export -f openssl curl dig

  certbot() { echo "CERTBOT_CALL $*" >> "$TEST_TMP/certbot_calls"; return 0; }
  export -f certbot

  run _ssl_provision_one "example.com" "ops@example.com" "" "user" "host" "$TEST_TMP" "demo"
  [ "$status" -eq 0 ]

  local first_call
  first_call=$(head -1 "$TEST_TMP/certbot_calls")
  [[ "$first_call" == *"--webroot"* ]]
  [[ "$first_call" == *"-d example.com"* ]]
  [[ "$first_call" == *"--email ops@example.com"* ]]
  [[ "$first_call" == *"--non-interactive"* ]]
  [[ "$first_call" == *"--agree-tos"* ]]
}

@test "_ssl_provision_one: falls back to --standalone (with the same flags) when --webroot fails" {
  docker() { :; }
  export -f docker
  openssl() { :; }
  curl() { echo "1.2.3.4"; }
  dig() { echo "1.2.3.4"; }
  export -f openssl curl dig

  certbot() {
    echo "CERTBOT_CALL $*" >> "$TEST_TMP/certbot_calls"
    [[ "$*" == *"--webroot"* ]] && return 1
    return 0
  }
  export -f certbot

  run _ssl_provision_one "example.com" "ops@example.com" "" "user" "host" "$TEST_TMP" "demo"
  [ "$status" -eq 0 ]

  local calls
  calls=$(cat "$TEST_TMP/certbot_calls")
  [[ "$calls" == *"--webroot"* ]]
  [[ "$calls" == *"--standalone"* ]]
  # The standalone attempt must ALSO carry -d/--email (already did pre-fix;
  # guards against a future regression removing them from that branch too).
  local standalone_call
  standalone_call=$(grep "standalone" "$TEST_TMP/certbot_calls")
  [[ "$standalone_call" == *"-d example.com"* ]]
  [[ "$standalone_call" == *"--email ops@example.com"* ]]
}

@test "_ssl_provision_one: skips provisioning when DNS doesn't resolve to the VPS" {
  docker() { :; }
  openssl() { :; }
  curl() { echo "1.2.3.4"; }
  dig() { echo "9.9.9.9"; }  # different IP — DNS not pointed here
  export -f docker openssl curl dig

  certbot() { echo "SHOULD_NOT_BE_CALLED"; }
  export -f certbot

  run _ssl_provision_one "example.com" "ops@example.com" "" "user" "host" "$TEST_TMP" "demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not resolve"* ]]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}
