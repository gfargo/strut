# Requirements Document

## Introduction

Strut currently hardcodes nginx as the reverse proxy in several engine modules: deploy reload, domain/SSL configuration, scaffold templates, drift detection, and VPS audit. This feature introduces a pluggable reverse proxy abstraction so that the engine dispatches proxy-specific behavior based on a `REVERSE_PROXY` config setting, with nginx as the default and Caddy as the first alternative. This follows strut's core design principle: no hardcoded values in the engine — everything config-driven.

## Glossary

- **Engine**: The strut shell library modules under `lib/` that implement CLI commands and orchestration logic
- **Reverse_Proxy_Config**: The `REVERSE_PROXY` key in `strut.conf` that selects which reverse proxy type the stack uses (valid values: `nginx`, `caddy`)
- **Proxy_Reload**: The operation that refreshes the reverse proxy's backend routing after a deploy (e.g., `nginx -s reload` or `caddy reload`)
- **Proxy_Config_Dir**: The directory within a stack that holds reverse proxy configuration files (e.g., `nginx/` or `caddy/`)
- **Drift_Tracked_File**: A configuration file monitored by the drift detection engine for changes between git-committed and VPS-runtime versions
- **Stack_Dir**: The directory `stacks/<name>/` containing all per-stack configuration, compose files, and proxy config
- **Config_Loader**: The `load_strut_config` function in `lib/config.sh` that sources `strut.conf` and applies defaults

## Requirements

### Requirement 1: Reverse Proxy Configuration Setting

**User Story:** As a stack operator, I want to declare which reverse proxy my stack uses in `strut.conf`, so that all engine commands automatically use the correct proxy type.

#### Acceptance Criteria

1. THE Config_Loader SHALL read a `REVERSE_PROXY` key from `strut.conf` and export it as an environment variable
2. WHEN `REVERSE_PROXY` is not set in `strut.conf`, THE Config_Loader SHALL default the value to `nginx`
3. IF `REVERSE_PROXY` is set to an unsupported value (not `nginx` or `caddy`), THEN THE Engine SHALL exit with a descriptive error message via `fail()`
4. THE `strut.conf.template` SHALL include a commented-out `REVERSE_PROXY` entry with documentation of valid values

### Requirement 2: Deploy Reload Dispatch

**User Story:** As a stack operator, I want the deploy command to reload whichever reverse proxy my stack uses, so that new container IPs are picked up after deploy regardless of proxy type.

#### Acceptance Criteria

1. WHEN `REVERSE_PROXY` is `nginx` and the nginx container is running, THE Engine SHALL execute `nginx -s reload` inside the nginx container after deploy
2. WHEN `REVERSE_PROXY` is `caddy` and the caddy container is running, THE Engine SHALL execute `caddy reload --config /etc/caddy/Caddyfile` inside the caddy container after deploy
3. WHEN the configured reverse proxy container is not running after deploy, THE Engine SHALL skip the reload step and emit a warning via `warn()`
4. THE deploy reload logic SHALL read the container service name from `REVERSE_PROXY` (the config value doubles as the compose service name)

### Requirement 3: Scaffold Proxy Templates

**User Story:** As a developer scaffolding a new stack, I want the scaffold command to generate the correct reverse proxy directory and config files based on `REVERSE_PROXY`, so that I start with a working proxy setup.

#### Acceptance Criteria

1. WHEN `REVERSE_PROXY` is `nginx`, THE Scaffold Command SHALL create an `nginx/` directory with a default `nginx.conf` and `conf.d/` subdirectory (current behavior)
2. WHEN `REVERSE_PROXY` is `caddy`, THE Scaffold Command SHALL create a `caddy/` directory with a default `Caddyfile`
3. THE scaffold "Next steps" output SHALL reference the correct proxy config directory based on `REVERSE_PROXY`
4. THE default Caddyfile template SHALL contain a placeholder reverse proxy block with a commented upstream target

### Requirement 4: Domain and SSL Configuration

**User Story:** As a stack operator, I want the `domain` command to configure SSL for both nginx and Caddy stacks, so that I can set up HTTPS regardless of which proxy I use.

#### Acceptance Criteria

1. WHEN `REVERSE_PROXY` is `nginx`, THE Domain Command SHALL execute the `configure-domain.sh` script on the VPS and pull back the nginx conf file (current behavior)
2. WHEN `REVERSE_PROXY` is `caddy`, THE Domain Command SHALL update the Caddyfile on the VPS with the domain configuration and reload Caddy
3. WHEN `REVERSE_PROXY` is `caddy`, THE Domain Command SHALL skip certbot-based SSL steps because Caddy handles automatic HTTPS via ACME
4. THE Domain Command SHALL pull back the updated proxy config file (nginx conf or Caddyfile) to the local repo after configuration
5. THE Domain Command SHALL restart the correct proxy container service name based on `REVERSE_PROXY` when committing SSL config changes

### Requirement 5: Drift Detection for Proxy Config

**User Story:** As a stack operator, I want drift detection to track the correct proxy config files based on my `REVERSE_PROXY` setting, so that configuration drift is caught for whichever proxy I use.

#### Acceptance Criteria

1. WHEN `REVERSE_PROXY` is `nginx`, THE Drift Engine SHALL include `nginx/nginx.conf` in the tracked files list (current behavior)
2. WHEN `REVERSE_PROXY` is `caddy`, THE Drift Engine SHALL include `caddy/Caddyfile` in the tracked files list instead of `nginx/nginx.conf`
3. WHEN `REVERSE_PROXY` is `nginx`, THE Drift Engine SHALL validate nginx config syntax using `nginx -t`
4. WHEN `REVERSE_PROXY` is `caddy`, THE Drift Engine SHALL validate Caddy config syntax using `caddy validate --config /etc/caddy/Caddyfile`

### Requirement 6: VPS Audit Proxy Detection

**User Story:** As a stack operator running a VPS audit, I want the audit to detect both nginx and Caddy containers and configurations, so that the audit report is accurate regardless of which proxy is in use.

#### Acceptance Criteria

1. THE Audit Engine SHALL detect running Caddy containers in addition to nginx containers
2. THE Audit Engine SHALL collect Caddy configuration files (`Caddyfile`) from detected Caddy containers
3. THE Audit Report SHALL include a section for Caddy configuration when Caddy containers are detected
4. THE Audit Engine SHALL check for both `nginx` and `caddy` system services when collecting service status

### Requirement 7: Health Check Network Port Discovery

**User Story:** As a stack operator, I want the health check network probe to detect the correct reverse proxy port dynamically, so that it works for proxies that may listen on ports other than 80.

#### Acceptance Criteria

1. WHEN `REVERSE_PROXY` is `nginx`, THE Health Engine SHALL include port 80 in the network port check (current behavior)
2. WHEN `REVERSE_PROXY` is `caddy`, THE Health Engine SHALL include both port 80 and port 443 in the network port check because Caddy listens on both by default
3. THE Health Engine SHALL read the reverse proxy ports from a `PROXY_PORTS` variable in `services.conf` when present, overriding the defaults

### Requirement 8: Dry-Run Proxy Awareness

**User Story:** As a stack operator previewing a deploy, I want the dry-run output to show the correct proxy reload command, so that I can verify the right proxy will be reloaded.

#### Acceptance Criteria

1. WHEN `DRY_RUN` is `true` and `REVERSE_PROXY` is `nginx`, THE Deploy Command SHALL show `nginx -s reload` in the execution plan
2. WHEN `DRY_RUN` is `true` and `REVERSE_PROXY` is `caddy`, THE Deploy Command SHALL show `caddy reload` in the execution plan
