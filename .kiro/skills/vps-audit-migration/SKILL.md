---
name: vps-audit-migration
description: Audit existing VPS Docker setups and migrate them to strut management. Use when onboarding a new VPS, discovering what's running on a server, generating stack definitions from existing containers, or running the interactive migration wizard.
---

# VPS Audit & Migration

Procedures for auditing existing VPS Docker setups and migrating them to strut management.

## Quick Reference

### Audit a VPS
```bash
# Basic audit
strut audit <vps-host> [vps-user] [ssh-key]

# Examples
strut audit 192.168.1.100 ubuntu
strut audit twenty-mcp-vps deploy 2222 ~/.ssh/my-key
```

### Run the Migration Wizard
```bash
# Interactive (step-by-step with prompts)
strut migrate <vps-host> [vps-user] [ssh-port] [ssh-key]

# Automated (auto-answers prompts, completes phases 1-5)
strut migrate <vps-host> [vps-user] [ssh-port] [ssh-key] --yes

# Resume from a specific phase
strut migrate <vps-host> [vps-user] --start-phase 4
```

### Generate Stack from Audit
```bash
strut audit:generate <stack-name> --from audits/<timestamp>-<host>
```

### List Past Audits
```bash
strut audit:list
```

## Audit System

### What Gets Audited

The audit discovers everything running on a VPS:

- Docker containers, volumes, networks, images
- Nginx configuration (container and system)
- Systemd services (running, enabled, custom)
- Cron jobs (user and system)
- Firewall rules (UFW, iptables)
- SSL certificates (Let's Encrypt, system)
- Database services (Postgres, MySQL, Redis, SQLite, MongoDB)
- Environment variable keys (names only, not values — intentional for security)
- Disk usage (overall and Docker-specific)
- Port usage

### Audit Output Structure

```
audits/<timestamp>-<host>/
├── REPORT.md                    # Human-readable full report
├── STACK_SUGGESTIONS.md         # Suggested stack groupings
├── containers.jsonl             # Container data
├── volumes.jsonl                # Volume data
├── networks.jsonl               # Network data
├── images.jsonl                 # Image data
├── ports.txt / disk-usage.txt   # Resource info
├── containers/                  # Detailed container inspections
├── compose-configs/             # Discovered docker-compose configs
├── nginx/                       # Nginx configs (container + system)
├── systemd/                     # Systemd service files
├── cron/                        # Cron jobs
├── firewall/                    # UFW + iptables rules
├── ssl/                         # SSL certificate info
├── databases/                   # Database containers + ports
├── secrets/                     # Env file key names
└── keys/                        # Categorized key discovery + migration guide
    ├── all-env-keys.txt
    ├── database-keys.txt
    ├── api-keys.txt
    ├── auth-keys.txt
    ├── service-keys.txt
    └── KEYS_MIGRATION.md
```

### Reviewing an Audit

```bash
# Full report
cat audits/<timestamp>-<host>/REPORT.md

# Stack suggestions (which containers to group)
cat audits/<timestamp>-<host>/STACK_SUGGESTIONS.md

# Keys migration guide
cat audits/<timestamp>-<host>/keys/KEYS_MIGRATION.md

# Nginx configs
cat audits/<timestamp>-<host>/nginx/*.conf

# Firewall rules
cat audits/<timestamp>-<host>/firewall/ufw-status.txt
```

## Migration Wizard (8 Phases)

The wizard orchestrates the complete migration process:

### Phase 1: Pre-flight Checks
- SSH connectivity test
- Docker installation check (offers to install if missing)
- Disk space verification (warns if >80% used)
- Container count discovery

### Phase 2: Setup strut on VPS
- Clones strut repo to VPS (handles GitHub auth: PAT, SSH key, or deploy key)
- Makes CLI executable
- Updates if already installed

**GitHub auth options:**
1. Personal Access Token (PAT) — easiest, wizard can auto-create via `gh` CLI
2. SSH key — uses existing or generates new
3. Deploy key — read-only, most secure for production

### Phase 3: Audit
- Runs full audit (same as `audit` command)
- Outputs REPORT.md and STACK_SUGGESTIONS.md

### Phase 4: Generate Stacks
- Shows suggested stacks from audit
- Prompts for stack names (comma-separated)
- Scaffolds docker-compose.yml and .env.template per stack
- Optionally pulls env keys from VPS containers

### Phase 5: Pre-Cutover Backup (Safety Net)
- Detects databases in each stack (Postgres, Neo4j, Redis)
- Creates backups from existing running containers
- Stores in `backups/pre-migration-<stack>-<timestamp>/`
- Generates ROLLBACK.md with recovery instructions

### Phase 6: Test Deployment (Interactive Only)
- Options: local testing or VPS parallel testing
- Deploys each stack, runs health checks
- Confirms success before continuing

### Phase 7: Cutover (Interactive Only)
- Lists old containers matching stack name
- Stops old containers (not removed)
- Ensures strut stacks are running
- Runs health checks

### Phase 8: Cleanup (Interactive Only)
- Removes stopped containers
- Runs `docker system prune`
- Preserves volumes (data is safe)

**Phases 6-8 are intentionally interactive** — they require manual decisions and validation.

## Stack Generation

### What Gets Generated

```bash
strut audit:generate twenty-crm --from audits/<timestamp>-<host>
```

Creates:
- `stacks/<stack>/docker-compose.yml` — service definitions from discovered containers
- `stacks/<stack>/.env.template` — placeholder env vars

### What You Must Customize

Generated files are starting points. You must:
1. Review port mappings
2. Add environment variable values (audit only captures key names)
3. Map volumes (reuse existing or create new)
4. Update health checks for your services
5. Add `depends_on` relationships
6. Configure networks

### Reusing Existing Docker Volumes

```yaml
volumes:
  postgres-data:
    external: true
    name: twenty_postgres_data  # Existing volume name from audit
```

## Common Workflows

### Workflow: Onboard a New VPS

```bash
# 1. Audit
strut audit 192.168.1.100 ubuntu

# 2. Review
cat audits/<latest>/REPORT.md
cat audits/<latest>/STACK_SUGGESTIONS.md

# 3. Generate stacks
strut audit:generate my-app --from audits/<latest>

# 4. Customize
nano stacks/my-app/docker-compose.yml
cp stacks/my-app/.env.template .my-app-prod.env
nano .my-app-prod.env  # Fill in secrets

# 5. Test
strut my-app deploy --env my-app-prod

# 6. Verify
strut my-app health --env my-app-prod
```

### Workflow: Full Interactive Migration

```bash
# Run wizard — it handles all 8 phases
strut migrate 192.168.1.100 ubuntu

# Follow prompts for each phase
# Review generated files between phases
# Test before cutover
```

### Workflow: Automated Migration (Phases 1-5)

```bash
# Auto-complete discovery + generation + backup
strut migrate 192.168.1.100 ubuntu --yes

# Then manually handle test/cutover/cleanup
strut <stack> deploy --env <stack>-prod
strut <stack> health --env <stack>-prod
```

### Workflow: Extract Keys from Running Containers

```bash
# SSH to VPS
ssh ubuntu@<vps-host>

# Get env vars from a container
docker exec <container-name> env | grep -E '(DATABASE|API|SECRET|SMTP)'

# Or inspect
docker inspect <container-name> --format='{{range .Config.Env}}{{println .}}{{end}}'
```

### Workflow: Compare Before and After Migration

```bash
# Audit before
strut audit 192.168.1.100

# ... migrate ...

# Audit after
strut audit 192.168.1.100

# Compare
diff audits/<before>/REPORT.md audits/<after>/REPORT.md
```

## Troubleshooting

### SSH Connection Fails
```bash
ssh -o ConnectTimeout=10 ubuntu@<vps-host>
ssh -i ~/.ssh/id_rsa ubuntu@<vps-host>
ssh-add ~/.ssh/id_rsa
```

### Git Clone Fails (Private Repo)
```bash
# Test PAT manually
git clone https://<PAT>@github.com/YOUR_ORG/strut.git test-clone

# Test SSH from VPS
ssh ubuntu@<vps-host> "ssh -T git@github.com"
```

### Docker Not Found
The wizard offers to install Docker. If it fails:
```bash
ssh ubuntu@<vps-host>
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker ubuntu
# Log out and back in
```

### Generated Stack Doesn't Work
1. Review TODO comments in generated docker-compose.yml
2. Check all env vars are filled in
3. Verify volume mappings
4. Check logs: `strut <stack> logs --follow`
5. Test incrementally — start with one service

### Backup Fails During Migration
- Check disk space: `df -h`
- Manually backup: `docker exec <container> pg_dump ...`
- Review `backups/pre-migration-*/ROLLBACK.md` for recovery

## Rollback from Migration

If migration goes wrong:
```bash
# Restart old containers
docker start <old-container-name>

# Stop strut stack
docker compose --project-name <stack>-prod down

# Restore from pre-migration backup
cat backups/pre-migration-<stack>-*/ROLLBACK.md
```

## Related Documentation

- `strut/AUDIT_QUICKSTART.md` — Quick start for audits
- `#stack-validation` — Validate generated stacks before deploying
- `#vps-deployment` — Deploy stacks after migration
- `#database-backups` — Backup procedures for migrated databases
