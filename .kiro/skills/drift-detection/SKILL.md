---
name: drift-detection
description: Detect and fix configuration drift between git-tracked files and VPS runtime configuration. Use when checking for unauthorized changes on VPS, setting up auto-fix, reviewing drift history, or troubleshooting config mismatches.
---

# Drift Detection & Auto-Fix

Procedures for detecting, reporting, and fixing configuration drift between git-tracked files and VPS runtime state.

## Quick Reference

```bash
# Detect drift
strut my-stack drift detect --env prod

# View detailed report
strut my-stack drift report --env prod

# Fix drift (apply git-tracked config to VPS)
strut my-stack drift fix --env prod

# Preview fix without applying
strut my-stack drift fix --dry-run --env prod

# View drift history
strut my-stack drift history --env prod

# Enable auto-fix
strut my-stack drift auto-fix enable --env prod

# Disable auto-fix
strut my-stack drift auto-fix disable --env prod
```

## What Is Drift?

Configuration drift occurs when VPS runtime configuration differs from git-tracked configuration. Common causes:
- Manual changes on VPS (emergency hotfixes, experiments)
- Failed deployments that partially applied
- Configuration experiments that weren't reverted
- Emergency hotfixes not committed back to git

## Detection

### Manual Detection

```bash
strut my-stack drift detect --env prod
```

Output shows which files have drifted and a summary of changes.

### Automatic Detection

Drift is detected hourly via cron. Configure the interval:

```bash
# Hourly (default)
0 * * * * /path/to/strut my-stack drift detect --env prod

# Every 30 minutes
*/30 * * * * /path/to/strut my-stack drift detect --env prod
```

### Drift Report

```bash
# Human-readable
strut my-stack drift report --env prod

# JSON (for scripting/monitoring)
strut my-stack drift report --env prod --json
```

The report shows per-file diffs between git and VPS versions, including git/VPS hashes.

## Fixing Drift

### Manual Fix

```bash
strut my-stack drift fix --env prod
```

Fix process:
1. Backs up current VPS configuration
2. Applies git-tracked configuration
3. Runs health checks
4. If health checks fail, restores backup
5. Logs fix event and sends notification

### Dry Run

```bash
strut my-stack drift fix --dry-run --env prod
```

Shows what would change: files to update, services to restart, estimated downtime.

### Auto-Fix

When enabled, drift is automatically corrected:

```bash
strut my-stack drift auto-fix enable --env prod
```

Auto-fix behavior:
- Drift detected hourly
- Git-tracked config applied automatically
- Backup created before every fix
- Health checks run after fix
- Rolls back if health checks fail
- Sends alert on fix or failure

Disable when doing intentional experiments:
```bash
strut my-stack drift auto-fix disable --env prod
```

## .drift-ignore

Some files legitimately differ from git at runtime. Add them to `.drift-ignore` in the stack directory:

```bash
# stacks/<stack>/.drift-ignore

# Runtime-generated
*.log
*.pid
*.sock

# Local overrides
.env
.env.local
docker-compose.override.yml

# Backup files
*.backup
*.bak

# SSL (managed at runtime by certbot)
nginx/conf.d/ssl.conf

# Temporary
tmp/*
cache/*
```

Supports glob patterns: `*`, `?`, `**`, `[abc]`.

## Drift History

```bash
strut my-stack drift history --env prod
```

Events stored in `stacks/<stack>/drift-history/` as JSON files with:
- Timestamp, stack, status
- Files that drifted (with git/VPS hashes and diffs)
- Resolution method (auto-fix, manual-fix, ignored)
- Health check result

## Common Workflows

### Emergency Hotfix (Intentional Drift)

```bash
# 1. Make emergency change on VPS
ssh ubuntu@<vps-host>
vim /path/to/config
docker compose restart

# 2. Drift will be detected on next check

# 3. Commit the change to git so drift resolves
git add config
git commit -m "Emergency hotfix: <description>"
git push

# 4. Drift resolves on next detection cycle
```

### Configuration Experiment

```bash
# 1. Disable auto-fix
strut my-stack drift auto-fix disable --env prod

# 2. Make experimental changes on VPS
# 3. Test changes
# 4. If successful, commit to git
# 5. Re-enable auto-fix
strut my-stack drift auto-fix enable --env prod
```

### Rollback After Bad Drift Fix

```bash
# Check drift backups
ls -la stacks/my-stack/drift-backups/

# Restore from backup
strut my-stack drift restore-backup <timestamp> --env prod

# Investigate
strut my-stack logs --follow --env prod
```

## Alerts

Drift alerts are sent when:
- Drift is detected (warning)
- Auto-fix applied successfully (info)
- Auto-fix failed (critical)
- Health checks failed after fix (critical)

Configure alert channels via the monitoring stack:
```bash
strut monitoring alert-channel add email --to alerts@yourdomain.com
```

## Troubleshooting

### False Positives

```bash
# Check file hashes manually
ssh <vps> "md5sum /path/to/file"
md5sum stacks/<stack>/docker-compose.yml

# Check line endings (CRLF vs LF)
file stacks/<stack>/docker-compose.yml

# Normalize
dos2unix stacks/<stack>/docker-compose.yml
```

### Drift Not Detected

```bash
# Check cron is running
crontab -l | grep drift

# Run manually
strut my-stack drift detect --env prod

# Check SSH connection
strut my-stack shell --env prod
```

### Auto-Fix Keeps Failing

```bash
# Check backup exists
ls -la stacks/<stack>/drift-backups/

# Restore manually
cp stacks/<stack>/drift-backups/<timestamp>/docker-compose.yml stacks/<stack>/

# Check health
strut my-stack health --env prod
```

## Best Practices

1. Use `.drift-ignore` for runtime-generated files
2. Enable auto-fix on production stacks
3. Review drift history weekly
4. Always commit emergency hotfixes back to git
5. Disable auto-fix before intentional experiments
6. Test health checks work before enabling auto-fix
7. Make changes in git, not on VPS — let deployments propagate

## Related Documentation

- `#stack-validation` — Validate stack config (includes basic drift check)
- `#vps-debugging` — Debug services after drift fix
- `#monitoring-setup` — Configure drift alerts
