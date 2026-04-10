---
name: key-rotation
description: Rotate and regenerate keys, credentials, and environment variables for strut VPS stacks. Use when rotating secrets on a schedule, responding to a security incident, onboarding/offboarding team members, or doing a full stack credential refresh.
---

# Key Rotation

Procedures for rotating all credentials associated with a strut VPS stack — SSH keys, API keys, database passwords, GitHub secrets, and environment variables.

## Key Types in a Stack

| Category | Where stored | CLI prefix | Affects |
|---|---|---|---|
| SSH keys | VPS `authorized_keys` + `keys/ssh-keys.json` | `keys ssh:*` | VPS access, CI/CD |
| API keys | `.env` `SEMANTIC_API_KEYS` + `keys/api-keys.json` | `keys api:*` | External consumers |
| Database passwords | `.env` + live DB | `keys db:rotate` | All services |
| GitHub secrets | GitHub repo secrets | `keys github:*` | CI/CD pipelines |
| Env var secrets | `.env` file | `keys env:*` | All services |

The `keys/` directory in each stack stores metadata only (fingerprints, masked values, dates) — never actual secrets.

## Quick Reference

```bash
# See everything tracked for a stack
strut my-stack keys inventory --env prod

# Discover secrets (local + VPS + GitHub)
strut my-stack keys discover --env prod

# Validate env file completeness
strut my-stack keys env:validate --env prod

# Audit SSH keys
strut my-stack keys ssh:audit --env prod
```

## Full Stack Rotation

Work through each step in order — database passwords require a redeploy, so batch changes.

### Step 1: Backup current state

```bash
strut my-stack keys env:backup --env prod
strut my-stack backup all --env prod
```

### Step 2: Rotate SSH keys

```bash
strut my-stack keys ssh:rotate <username> --env prod
strut my-stack keys ssh:audit --env prod

# Push new VPS deploy key to all repos
strut my-stack keys github:rotate-vps-key \
  --repos "YOUR_ORG/my-service,YOUR_ORG/my-agent,YOUR_ORG/my-ops,YOUR_ORG/my-whatsapp,YOUR_ORG/my-chatbot,YOUR_ORG/my-ingest,YOUR_ORG/my-gdrive"
```

### Step 3: Rotate database passwords

```bash
strut my-stack keys db:rotate postgres --env prod
strut my-stack keys db:rotate neo4j --env prod

# Redeploy immediately
strut my-stack release --env prod
strut my-stack health --env prod
```

### Step 4: Rotate env var secrets

```bash
# Auto-rotatable secrets
strut my-stack keys env:rotate --env prod

# Third-party keys (rotate in external service first, then update)
strut my-stack keys env:set MISTRAL_API_KEY "new-key" --env prod
strut my-stack keys env:set GH_PAT "ghp_new..." --env prod
```

### Step 5: Rotate API keys

```bash
strut my-stack keys api:list
strut my-stack keys api:rotate <key-name>
```

### Step 6: Sync GitHub secrets

```bash
while IFS= read -r repo; do
  [[ "$repo" =~ ^# ]] && continue
  [[ -z "$repo" ]] && continue
  strut my-stack keys github:sync --repo "$repo" --from .prod.env
done < strut/stacks/my-stack/repos.conf
```

### Step 7: Final verification

```bash
strut my-stack keys env:validate --env prod
strut my-stack keys env:diff --local .prod.env --remote --env prod
strut my-stack health --env prod --json
strut my-stack keys ssh:audit --env prod
```

## Rotation Schedule

| Secret type | Interval | Also rotate on |
|---|---|---|
| SSH keys | 90 days | Team member departure |
| `GH_PAT` | 90 days | GitHub expiry warning |
| Database passwords | 90 days | Suspected breach |
| Semantic API keys | 90 days | Consumer offboarding |
| Third-party API keys | Per provider | Suspected exposure |

Audit log: `stacks/<stack>/keys/key-audit.log`

## Troubleshooting

### Services down after rotation

```bash
strut my-stack logs --tail 100 --env prod
# Most common: services didn't pick up new DB password → redeploy
strut my-stack release --env prod
```

### SSH key not working

```bash
strut my-stack keys ssh:audit --env prod
ssh -i ~/.ssh/strut-<stack>-vps ubuntu@<VPS_HOST> "echo ok"
```

### Rotation failed mid-process

```bash
ls strut/.env.backup-*
cp strut/.env.backup-YYYYMMDD-HHMMSS strut/.prod.env
strut my-stack release --env prod
```

## Related Documentation

