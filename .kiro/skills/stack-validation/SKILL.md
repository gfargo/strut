---
name: stack-validation
description: Validate and check the integrity of strut stacks. Use when creating a new stack, auditing an existing stack's configuration, or verifying a stack is correctly structured before deployment.
---

# Stack Validation

Procedures for validating, checking, and auditing strut stacks — whether creating a new one or verifying an existing one is healthy.

## Quick Validation (Existing Stack)

```bash
# 1. Runtime health
strut my-stack health --env prod

# 2. Config drift vs git
strut my-stack drift detect --env prod

# 3. Postgres schema matches SQL init files
strut my-stack schema verify --env prod

# 4. Env vars against template
strut my-stack keys env:validate --env prod

# 5. Backup health
strut my-stack backup health --env prod
```

## New Stack Checklist

### 1. Required Files

Every stack lives under `strut/stacks/<stack-name>/`:

```
stacks/<stack-name>/
├── docker-compose.yml          # required
├── docker-compose.local.yml    # required
├── .env.template               # required
├── .drift-ignore               # recommended
├── backup.conf                 # recommended
├── repos.conf                  # recommended
├── nginx/                      # if using reverse proxy
├── sql/init/                   # Postgres DDL (auto-applied on first start)
└── config/                     # runtime config files
```

### 2. docker-compose.yml Validation

```bash
# Syntax check
docker compose -f strut/stacks/<stack-name>/docker-compose.yml config --quiet

# Full resolved config
docker compose -f strut/stacks/<stack-name>/docker-compose.yml \
  --env-file strut/stacks/<stack-name>/.env config
```

Verify manually:
- All services have `restart: unless-stopped` and `healthcheck`
- Database-dependent services use `condition: service_healthy`
- Optional services use `profiles:`
- No hardcoded secrets — use `${VAR}` substitution

### 3. Environment Variable Validation

```bash
# Compare template vs actual
diff \
  <(grep -E '^[A-Z_]+=?' strut/stacks/<stack-name>/.env.template | cut -d= -f1 | sort) \
  <(grep -E '^[A-Z_]+=?' strut/stacks/<stack-name>/.env | cut -d= -f1 | sort)

# Check for unfilled placeholders
grep -E '(your-|change-me|xxxx|placeholder|TODO)' strut/stacks/<stack-name>/.env
```

Required variables for any stack:

| Variable | Purpose |
|---|---|
| `VPS_HOST` | SSH target |
| `VPS_USER` | SSH user |
| `VPS_DEPLOY_DIR` | strut path on VPS |
| `GH_PAT` | GitHub PAT for private images |
| `COMPOSE_PROJECT_NAME` | Docker project name |

### 4. Postgres Schema Validation

```bash
strut <stack-name> schema verify --env prod
ls -la strut/stacks/<stack-name>/sql/init/   # Should be 01_*.sql, 02_*.sql, etc.
```

### 5. Drift Configuration

Ensure `.drift-ignore` excludes runtime-generated files:

```
*.log
*.pid
.env
.env.local
docker-compose.override.yml
*.backup
nginx/conf.d/ssl.conf
```

### 6. Backup Configuration

Verify `backup.conf` has sensible defaults:

```bash
BACKUP_SCHEDULE_POSTGRES="0 2 * * *"
BACKUP_RETAIN_DAYS=30
BACKUP_RETAIN_COUNT=10
BACKUP_POSTGRES=true
```

Test: `strut <stack-name> backup all --env prod`

## Full Integrity Audit

```bash
strut <stack-name> health --env prod --json
strut <stack-name> status --env prod
strut <stack-name> drift detect --env prod
strut <stack-name> schema verify --env prod
strut <stack-name> backup health --env prod
strut <stack-name> resources current --env prod
strut <stack-name> keys inventory
```

## Common Validation Failures

### docker-compose.yml syntax error
Tabs instead of spaces, missing quotes, incorrect indentation, undefined `${VAR}` references.

### Missing required env vars
```bash
diff <(grep -E '^[A-Z_]+=' .env.template | cut -d= -f1 | sort) <(grep -E '^[A-Z_]+=' .env | cut -d= -f1 | sort)
```

### Service fails healthcheck
```bash
strut <stack-name> logs <service> --tail 50 --env prod
```

### Drift detected after first deploy
Add runtime files to `.drift-ignore`, or fix real config changes with `drift fix`.

## Stack Structure Reference

- Minimal: `docker-compose.yml` + `docker-compose.local.yml` + `.env.template` + `.drift-ignore`
- Standard: + `backup.conf` + `repos.conf` + `nginx/` + `sql/init/`
- Full (my-stack pattern): + `volume.conf` + `config/` + `keys/` + `drift-history/`

## Related Documentation

