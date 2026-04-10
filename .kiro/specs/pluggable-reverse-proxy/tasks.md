# Implementation Plan: Pluggable Reverse Proxy

## Overview

Add pluggable reverse proxy support to strut so that proxy-specific behavior (reload, scaffold, domain/SSL, drift, audit, health) dispatches based on a `REVERSE_PROXY` config setting. Nginx remains the default; Caddy is the first alternative. Each engine module that currently hardcodes nginx will be updated to read `REVERSE_PROXY` and dispatch accordingly via `case` statements.

## Tasks

- [x] 1. Add REVERSE_PROXY to config loading and template
  - [x] 1.1 Add REVERSE_PROXY default and validation to `lib/config.sh`
    - In `load_strut_config()`, after existing defaults, add `REVERSE_PROXY="${REVERSE_PROXY:-nginx}"` and `export REVERSE_PROXY`
    - Add a `case` validation block that calls `fail()` for values other than `nginx` or `caddy`
    - _Requirements: 1.1, 1.2, 1.3_

  - [x] 1.2 Write property test: Config parsing loads REVERSE_PROXY and defaults to nginx
    - **Property 1: Config parsing loads REVERSE_PROXY and defaults to nginx**
    - Create `tests/test_proxy_config.bats` with 100-iteration randomized test
    - Generate random `strut.conf` with random subset of config keys including `REVERSE_PROXY`
    - Verify `load_strut_config` exports correct values and defaults `REVERSE_PROXY` to `nginx` when absent
    - **Validates: Requirements 1.1, 1.2**

  - [x] 1.3 Write property test: Invalid REVERSE_PROXY values are rejected
    - **Property 2: Invalid REVERSE_PROXY values are rejected**
    - Generate 100 random strings (excluding "nginx" and "caddy")
    - Verify `load_strut_config` fails for each invalid value
    - **Validates: Requirements 1.3**

  - [x] 1.4 Add REVERSE_PROXY entry to `templates/strut.conf.template`
    - Add a commented `# ── Reverse Proxy ──` section with `# REVERSE_PROXY=nginx` and documentation of valid values (`nginx | caddy`)
    - _Requirements: 1.4_

- [x] 2. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 3. Implement proxy-aware deploy reload in `lib/deploy.sh`
  - [x] 3.1 Replace hardcoded nginx reload in `deploy_stack()` with proxy dispatch
    - Read `local proxy="${REVERSE_PROXY:-nginx}"` and use it as the compose service name in `$compose_cmd ps` and `$compose_cmd exec`
    - Add `case "$proxy"` with `nginx)` branch (`nginx -s reload`) and `caddy)` branch (`caddy reload --config /etc/caddy/Caddyfile`)
    - Emit `warn()` when proxy container is not running, skip reload
    - _Requirements: 2.1, 2.2, 2.3, 2.4_

  - [x] 3.2 Update dry-run block in `deploy_stack()` to show correct proxy reload command
    - Add a `run_cmd` line that shows the proxy-specific reload command based on `REVERSE_PROXY`
    - _Requirements: 8.1, 8.2_

  - [x] 3.3 Write property test: Dry-run output shows correct proxy reload command
    - **Property 7: Dry-run output shows correct proxy reload command per REVERSE_PROXY**
    - For each valid `REVERSE_PROXY` value with `DRY_RUN=true`, verify output contains the proxy-specific reload command
    - **Validates: Requirements 8.1, 8.2**

- [x] 4. Implement proxy-aware scaffold in `lib/cmd_scaffold.sh`
  - [x] 4.1 Replace hardcoded nginx directory creation with proxy dispatch
    - Read `local proxy="${REVERSE_PROXY:-nginx}"` and add `case "$proxy"` block
    - `nginx)` branch: keep existing `mkdir -p "$target/nginx/conf.d"` and `nginx.conf` creation
    - `caddy)` branch: `mkdir -p "$target/caddy"` and write a default `Caddyfile` with placeholder reverse_proxy block
    - Update "Next steps" echo to reference the correct proxy config directory
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

  - [x] 4.2 Write property test: Scaffold creates correct proxy directory
    - **Property 3: Scaffold creates correct proxy directory per REVERSE_PROXY**
    - For each valid proxy type, run `cmd_scaffold` and verify correct directory structure and config file content
    - **Validates: Requirements 3.1, 3.2, 3.3**

- [x] 5. Implement proxy-aware domain/SSL in `lib/cmd_domain.sh`
  - [x] 5.1 Add proxy dispatch to `cmd_domain()`
    - Read `local proxy="${REVERSE_PROXY:-nginx}"` and wrap existing nginx logic in `case "$proxy"` `nginx)` branch
    - Add `caddy)` branch: update Caddyfile on VPS with domain block, reload Caddy (skip certbot), pull back Caddyfile
    - Update the git commit/push section to restart the correct proxy service name and pull back the correct config file
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

- [x] 6. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 7. Implement proxy-aware drift detection in `lib/drift.sh`
  - [x] 7.1 Replace static `DRIFT_TRACKED_FILES` array with `drift_get_tracked_files()` function
    - Create `drift_get_tracked_files()` that returns base files plus the proxy-specific config file based on `REVERSE_PROXY`
    - `nginx)` → append `nginx/nginx.conf`; `caddy)` → append `caddy/Caddyfile`
    - Update all references to `DRIFT_TRACKED_FILES` array to call `drift_get_tracked_files()` instead (in `drift_detect`, `drift_fix`, `drift_report`, `drift_monitor`)
    - _Requirements: 5.1, 5.2_

  - [x] 7.2 Add Caddyfile validation case to `drift_validate_syntax()`
    - Add `Caddyfile)` case that runs `caddy validate --config "$file_path"` when `caddy` binary is available
    - _Requirements: 5.3, 5.4_

  - [x] 7.3 Write property test: Drift tracked files include correct proxy config
    - **Property 4: Drift tracked files include correct proxy config per REVERSE_PROXY**
    - For each valid proxy type, call `drift_get_tracked_files` and verify correct proxy config file is included and the other proxy's file is not
    - **Validates: Requirements 5.1, 5.2**

- [x] 8. Implement proxy-aware health check network in `lib/health.sh`
  - [x] 8.1 Replace hardcoded port 80 in `health_check_network()` with proxy-aware defaults
    - Read `local proxy="${REVERSE_PROXY:-nginx}"` and check for `PROXY_PORTS` override from `services.conf`
    - If `PROXY_PORTS` is set, use those ports; otherwise `nginx)` → `(80)`, `caddy)` → `(80 443)`
    - _Requirements: 7.1, 7.2, 7.3_

  - [x] 8.2 Write property test: Health engine checks correct default ports
    - **Property 5: Health engine checks correct default ports per REVERSE_PROXY**
    - For each valid proxy type with no `PROXY_PORTS`, verify correct default ports
    - **Validates: Requirements 7.1, 7.2**

  - [x] 8.3 Write property test: PROXY_PORTS override replaces default proxy ports
    - **Property 6: PROXY_PORTS override replaces default proxy ports**
    - Generate random port lists, set as `PROXY_PORTS`, verify health engine uses exactly those ports
    - **Validates: Requirements 7.3**

- [x] 9. Implement Caddy audit detection in `lib/audit.sh`
  - [x] 9.1 Add `_audit_caddy()` function and wire into `audit_vps()`
    - Create `_audit_caddy()` parallel to `_audit_nginx()`: detect Caddy containers, extract Caddyfile configs, check system service
    - Call `_audit_caddy` after `_audit_nginx` in `audit_vps()`
    - _Requirements: 6.1, 6.2, 6.4_

  - [x] 9.2 Add Caddy section to `audit_generate_report()`
    - Include Caddy containers and configuration in the audit report markdown, parallel to the existing nginx section
    - _Requirements: 6.3_

- [x] 10. Update existing tests for proxy awareness
  - [x] 10.1 Extend `tests/test_config.bats` to include REVERSE_PROXY in randomized key set
    - Add `REVERSE_PROXY` to the config keys tested in existing property tests
    - _Requirements: 1.1, 1.2_

  - [x] 10.2 Update `tests/test_scaffold.bats` to verify proxy-aware scaffold output
    - Add test cases that verify scaffold creates correct proxy directory for both nginx and caddy
    - _Requirements: 3.1, 3.2_

  - [x] 10.3 Update `tests/test_no_hardcodes.bats` to verify no remaining hardcoded nginx in dispatch paths
    - Ensure grep patterns exclude the nginx-specific case branches but catch any remaining hardcoded nginx references in engine dispatch logic
    - _Requirements: 1.1, 2.1, 3.1_

- [x] 11. Final checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- All code is Bash; tests use BATS with 100-iteration randomized property tests
