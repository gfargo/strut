---
name: vps-deployment
description: Step-by-step procedures for deploying strut services to VPS using strut. Use when deploying to production, updating services, managing releases, or configuring VPS infrastructure.
---

# VPS Deployment

## Quick Deploy

```bash
strut my-stack release --env prod --dry-run   # Preview
strut my-stack release --env prod             # Full release
```

Release automatically: updates repo on VPS → runs migrations → deploys → verifies health.

## Manual Deploy Steps

```bash
strut my-stack update --env prod              # Sync strut repo on VPS
strut my-stack deploy --env prod              # Deploy containers
strut my-stack health --env prod --json       # Verify
```

## Stop Containers

```bash
strut my-stack stop --env prod                # Stop containers
strut my-stack stop --env prod --volumes      # Stop + remove volumes
strut my-stack stop --env prod --dry-run      # Preview
```

## Service Profiles

```bash
strut my-stack deploy --env prod                          # core (default)
strut my-stack deploy --env prod --services messaging     # + messaging
strut my-stack deploy --env prod --services full          # everything
```

## First-Time Setup

1. Create env file from template, fill in secrets (VPS_HOST, registry creds, DB passwords)
2. Configure `strut.conf` with registry type and org
3. Deploy: `strut my-stack release --env prod`

## SSL Configuration

```bash
strut my-stack domain api.example.com admin@example.com --env prod
```

## Migrations

```bash
strut my-stack migrate postgres --status --env prod   # Check
strut my-stack migrate postgres --up --env prod       # Apply
strut my-stack migrate neo4j --down 1 --env prod      # Rollback
```

## Monitoring

```bash
strut my-stack health --env prod --json
strut my-stack logs my-service --follow --env prod
strut my-stack status --env prod
```

## Best Practices

1. Always `--dry-run` first for destructive commands
2. Backup before major changes: `strut my-stack backup all --env prod`
3. Use `release` for VPS (runs remotely), not `deploy` (runs locally)
4. Health checks are driven by `services.conf` — keep it up to date

## Local vs VPS

- `deploy` / `stop` — runs locally, or on VPS if VPS_HOST is set
- `release` — always runs on VPS via SSH
- `update` — syncs strut repo on VPS (no container restart)
- `shell` / `exec` — SSH to VPS
