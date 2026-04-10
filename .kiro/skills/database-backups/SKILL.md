---
name: database-backups
description: Backup and restore procedures for strut databases (Postgres, Neo4j, MySQL, SQLite) using strut. Use when backing up data, restoring from backups, or managing database snapshots.
---

# Database Backups & Restore

Backup and restore procedures for strut databases (Postgres, Neo4j, MySQL, SQLite) using strut.

## Quick Reference

### Create Backups on VPS

```bash
# Backup Postgres (my-stack)
strut my-stack backup postgres --env prod

# Backup Neo4j (my-stack)
strut my-stack backup neo4j --env prod

# Backup MySQL (docspace)
strut docspace backup mysql --env docspace-prod

# Backup SQLite (jitsi)
strut jitsi backup sqlite --env jitsi-prod

# Backup all enabled targets for a stack
strut my-stack backup all --env prod
```

### Pull Production Data to Local

```bash
# Pull and restore all databases
strut my-stack db:pull --env prod

# Pull specific database type
strut my-stack db:pull postgres --env prod

# Download only (no restore)
strut my-stack db:pull --env prod --download-only
```

### Push Local Data to Production

```bash
# Push and restore Postgres (⚠️ overwrites production data)
strut my-stack db:push postgres --env prod --file backups/postgres-20260303-143022.sql

# Preview first with --dry-run
strut my-stack db:push postgres --env prod --file backups/postgres.sql --dry-run
```

## Stack Database Matrix

| Stack | Postgres | Neo4j | MySQL | SQLite | VPS |
|-------|----------|-------|-------|--------|-----|
| my-stack | ✅ | ✅ | — | — | 164.92.160.148 |
| docspace | — | — | ✅ (8.3.0) | — | 83.228.220.209 |
| jitsi | — | — | — | ✅ | 83.228.221.129 |

Notes:
- DocSpace MySQL runs in Docker container `onlyoffice-mysql-server`
- Jitsi SQLite is inside a Docker volume (`BACKUP_SQLITE_USE_DOCKER=true` in `backup.conf`)
- Stacks with `VPS_SUDO=yes` require `VPS_SUDO=true` in their env file

## Backup Verification

```bash
# Verify a specific backup
strut my-stack backup verify backups/postgres-20260315-020000.sql --env prod

# Verify all backups in a stack
strut my-stack backup verify-all --env prod

# View health scores (0-100)
strut my-stack backup health --env prod
```

## Backup Retention & Scheduling

### Configuration via backup.conf

Each stack has a `backup.conf` controlling schedules and retention:

```bash
# strut/stacks/<stack>/backup.conf
BACKUP_POSTGRES=true
BACKUP_SCHEDULE_POSTGRES="0 2 * * *"   # 02:00 UTC daily
BACKUP_RETAIN_DAYS=30
BACKUP_RETAIN_COUNT=10
```

### Schedule Management

```bash
strut my-stack backup schedule install-defaults --env prod
strut my-stack backup schedule list --env prod
strut my-stack backup cleanup --env prod
```

## Common Scenarios

### Refresh Local Dev Environment

```bash
strut my-stack db:pull --env prod
```

### Test Migration Locally

```bash
strut my-stack db:pull --env prod
strut my-stack migrate neo4j --up --env prod
# Test, then apply to prod:
strut my-stack migrate neo4j --up --env prod
```

### Recover from Bad Migration

```bash
strut my-stack db:pull postgres --env prod --file postgres-20260303-143022.sql
strut my-stack migrate neo4j --down 1 --env prod
strut my-stack health --env prod
```

## Prerequisites

- strut must be installed on VPS (`strut migrate` for new VPS)
- `VPS_SUDO=true` in env file for stacks requiring sudo Docker access
- Stack env file (`.prod.env`, `.jitsi-prod.env`, etc.) with VPS connection details

## Troubleshooting

### Backup Fails

```bash
strut my-stack exec "df -h /" --env prod          # Check disk space
strut my-stack exec "docker compose --project-name prod exec postgres pg_isready" --env prod
```

### Pull/Push Fails

```bash
strut my-stack shell --env prod                    # Check SSH access
grep VPS_HOST strut/.prod.env                                    # Check VPS_HOST
```

## Related Documentation

- `strut/lib/backup.sh` — Main backup script
- `strut/lib/backup/` — DB-specific backup implementations
