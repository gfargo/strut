---
inclusion: auto
keywords: ["deploy", "stack", "vps", "strut", "docker-compose", "deployment", "release", "health", "backup", "restore", "container", "service", "monitoring", "stop"]
description: "strut CLI usage and stack management for VPS deployments"
---

# Stack Management with strut

strut is a generic CLI for multi-VPS stack orchestration. All deployment operations go through the unified `strut` command.

## CLI Entrypoint

```bash
strut <stack> <command> [--env <name>] [options]
```

## Core Concepts

### Stacks

A stack is a deployment unit: `docker-compose.yml` + env config + services, living under `stacks/<name>/`.

Each stack can have:
- `docker-compose.yml` — service definitions
- `services.conf` — service ports, health paths, DB flags (drives health checks)
- `required_vars` — env vars that must be set before deploy
- `volume.conf` — volume path mappings and ownership
- `repos.conf` — GitHub repos for key management
- `backup.conf` — backup schedule configuration
- `anonymize.conf` — PII anonymization rules for sync-db
- `hooks/pre-deploy.sh` — custom pre-deploy validation script

### Environments

The `--env` flag maps to dotfiles at the project root:
- `--env prod` → `.prod.env`
- `--env staging` → `.staging.env`
- `--env local` → `.local.env`

### Configuration

Project-level settings live in `strut.conf` at the project root:
- `REGISTRY_TYPE` — container registry (ghcr, dockerhub, ecr, none)
- `DEFAULT_ORG` — GitHub/registry organization
- `DEFAULT_BRANCH` — git branch for VPS sync
- `REVERSE_PROXY` — reverse proxy type (nginx, caddy)
- `ROLLBACK_RETENTION` — number of deploy snapshots to keep (default: 5)
- `PRE_DEPLOY_VALIDATE` — run config validation before deploy (default: true)
- `PRE_DEPLOY_HOOKS` — run custom hooks before deploy (default: true)
- `BANNER_TEXT` — branding in CLI output

## Essential Commands

```bash
# Deploy / Release
strut <stack> release --env prod              # Full VPS release (recommended)
strut <stack> deploy --env prod               # Local deploy
strut <stack> deploy --env prod --skip-validation  # Emergency deploy (skip checks)
strut <stack> update --env prod               # Update strut scripts on VPS only
strut <stack> stop --env prod                 # Stop running containers
strut <stack> rollback --env prod             # Roll back to previous deploy

# Validation & Diagnostics
strut <stack> validate --env prod             # Validate all config files
strut doctor                                  # Check environment health
strut doctor --check-vps --fix                # Include VPS checks, show fixes

# Monitoring
strut <stack> health --env prod
strut <stack> health --env prod --json
strut <stack> logs <service> --tail 100 --env prod
strut <stack> status --env prod

# Database
strut <stack> backup all --env prod
strut <stack> backup postgres --env prod --dry-run
strut <stack> db:pull --env prod
strut <stack> local sync-db --from prod --anonymize

# VPS Access
strut <stack> shell --env prod                # Interactive SSH
strut <stack> exec "docker ps" --env prod     # Single command

# Dry-run (preview destructive commands)
strut <stack> release --env prod --dry-run
strut <stack> stop --env prod --dry-run
strut <stack> backup postgres --env prod --dry-run
strut <stack> rollback --env prod --dry-run
```

## Local vs VPS Execution

- `deploy` — runs locally (local Docker), or on VPS if SSH'd in
- `release` — runs on VPS via SSH (update + migrate + deploy + verify)
- `stop` — stops locally, or on VPS if VPS_HOST is set
- `update` — pulls latest strut scripts on VPS (no container restart)
- `shell` / `exec` — SSH to VPS

## Service Profiles

```bash
strut <stack> deploy --env prod                       # core (default)
strut <stack> deploy --env prod --services messaging  # + messaging services
strut <stack> deploy --env prod --services full       # all services
```

## Project Initialization

```bash
strut init --registry ghcr --org my-org    # Bootstrap new project
strut scaffold my-app                       # Create new stack from templates
strut --version                             # Show installed version
strut upgrade                               # Pull latest strut version
```

## Related Skills

For step-by-step procedural workflows, use these skills:

- `vps-deployment` — Deploy and release to VPS
- `vps-debugging` — Troubleshoot production issues
- `database-backups` — Backup/restore procedures
- `key-rotation` — Credential rotation workflows
- `stack-validation` — Validate stack configuration
- `drift-detection` — Config drift detection and auto-fix
- `monitoring-setup` — Prometheus/Grafana deployment
- `domain-ssl` — Domain and SSL certificate setup
- `vps-audit-migration` — Audit VPS and migrate to strut
