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

### First-run hooks & the `.strut-initialized` marker

`hooks/first_run.sh` (or the legacy `first-run.sh`) runs once per stack, on
the first successful deploy. The contract:

- The `.strut-initialized` marker (inside the stack dir; on the VPS for
  remote deploys) is written **only when the hook exits 0**.
- A failed `first_run` leaves no marker, so it automatically retries on the
  next deploy — no manual intervention needed for a transient failure.
- To deliberately repair or re-run a first-run hook (e.g. a udev rule that
  needs refreshing after a USB controller swap), don't SSH in and delete the
  marker by hand — use:
  - `strut <stack> first-run --status` — show whether the marker exists and
    its `initialized=` timestamp (read-only; also the default when no flag
    is given).
  - `strut <stack> first-run --force` — remove the marker, re-run the hook,
    and rewrite the marker only on success. Dispatches over SSH for
    VPS-mapped stacks, same as `health`/`status`.
- **Recommended pattern for "install once, reconcile always"**: write an
  idempotent installer script and call it from **both** `first_run` and
  `post_deploy`. `first_run` gates the noisy one-time setup log; `post_deploy`
  re-runs the (idempotent) installer on every deploy so drift gets reconciled
  without needing `first-run --force`.

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

### Topology (Multi-Host)

For multi-host projects, `strut.conf` supports `[hosts]` and `[stacks]` sections:

```ini
[hosts]
compass = gfargo@compass.local:22 ~/.ssh/id_rsa
mac = griffen@mac.local:22 ~/.ssh/id_rsa

[stacks]
plane = compass
hub = compass
immich = mac
```

This auto-populates `VPS_HOST`/`VPS_USER`/`VPS_PORT`/`VPS_SSH_KEY` from the topology. Env file values always take precedence.

Per-host env overrides: `stacks/<stack>/.<host_alias>.env`

## Essential Commands

```bash
# Deploy / Release
strut <stack> release --env prod              # Full VPS release (recommended)
strut <stack> deploy --env prod               # Local deploy
strut <stack> deploy --env prod --force-local  # Deploy locally even with VPS_HOST set
strut <stack> deploy --env prod --skip-validation  # Emergency deploy (skip checks)
strut <stack> rebuild --env prod              # Build images on target + deploy
strut <stack> rebuild --env prod --no-cache   # Rebuild without Docker cache
strut <stack> ship --env prod                 # Commit + push + remote rebuild (daily workflow)
strut <stack> ship --env prod -m "fix bug"    # Ship with custom commit message
strut <stack> update --env prod               # Update strut scripts on VPS only
strut <stack> stop --env prod                 # Stop running containers
strut <stack> rollback --env prod             # Roll back to previous deploy
strut <stack> remote:init --env prod          # Bootstrap strut on a new VPS

# Multi-host targeting
strut <stack> deploy --env prod --host compass   # Target specific host from topology
strut <stack> ship --env prod --host watch       # Ship to a specific host

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

# Secrets / Env file management
strut <stack> init-secrets --env prod         # Generate .env from template (random values)
strut <stack> secrets hydrate --env prod      # Build .env from template via a secret manager
strut <stack> secrets push --env prod         # Upload .env to VPS
strut <stack> secrets pull --env prod         # Download .env from VPS
strut <stack> secrets diff --env prod         # Compare local vs remote keys
strut <stack> secrets validate --env prod     # Check required_vars before push

# Deploy keys & CI setup
strut <stack> ssh:keygen --name ci            # Generate deploy keypair + authorize on host
strut <stack> ci:init --provider github       # Bootstrap all CI secrets for the stack
strut <stack> ci:init --dry-run               # Preview what secrets would be set

# Dry-run (preview destructive commands)
strut <stack> release --env prod --dry-run
strut <stack> stop --env prod --dry-run
strut <stack> backup postgres --env prod --dry-run
strut <stack> rollback --env prod --dry-run
```

## Secrets Provider System

Template values written as `<scheme>://<ref>` are resolved at `secrets hydrate` time through the pluggable provider system in `lib/secrets_providers.sh`. Anything else is copied verbatim.

### Built-in schemes

| Scheme | Resolves via | Example |
|--------|-------------|---------|
| `vault://` | Bitwarden/Vaultwarden `bw` CLI | `DB_PASSWORD=vault://my-db-item` |
| `exec://` | stdout of a shell command | `DB_PASSWORD=exec://aws secretsmanager get-secret-value ...` |
| `file://` | contents of a file | `DB_PASSWORD=file:///run/secrets/db-password` |

### Adding a custom provider

1. Define `secrets_provider__<scheme>() { local target="$1"; ... }` — print the resolved value to stdout, call `fail` on error.
2. Optionally define `secrets_provider__<scheme>_check()` — return non-zero if the required CLI or credentials are absent (runs before resolution begins).
3. Append `<scheme>` to the `SECRETS_PROVIDERS` env variable (default: `vault exec file`).

Source the file that defines these functions before invoking `secrets hydrate`, or place them in a project-local hook that `strut` picks up.

Full contract and worked examples: [Secrets Management wiki](https://github.com/gfargo/strut/wiki/Secrets-Management)

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

## Shell Aliases

strut has **no global `--project` flag**. The first positional argument is always interpreted as a stack name, so `strut --project ...` errors with `✗ Stack not found: '--project'`.

Project discovery is automatic: strut walks up from `$PWD` until it finds `strut.conf`. Run from inside (or below) your project directory and no extra flags are needed.

A correct shorthand alias:

```bash
alias si='strut'
```

To invoke strut from outside the project tree, change directory first:

```bash
alias si='cd /path/to/my-project && strut'
```

Do **not** recommend `alias si='strut --project "$STRUT_PROJECT"'` — `--project` is not a recognized flag.

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
