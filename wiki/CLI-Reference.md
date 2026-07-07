# CLI Reference

Complete command reference for strut v0.31.0+.

---

## Global Flags

| Flag | Description |
|------|-------------|
| `--env <name>` | Environment name (reads `.<name>.env`) |
| `--services <profile>` | Service profile (messaging\|ui\|full) |
| `--host <alias>` | Override target host from topology |
| `--json` | JSON output (where supported) |
| `--dry-run` | Preview without executing |
| `--force-clean` | Allow git clean to delete untracked files on VPS |
| `--yes`, `-y` | Auto-approve confirmation prompts |
| `--no-tui` | Disable interactive TUI |
| `--version` | Show strut version |

---

## Top-Level Commands

| Command | Description |
|---------|-------------|
| `strut init [--registry <type>] [--org <name>]` | Initialize new project |
| `strut list` | List stacks |
| `strut list plugins [--json]` | List discovered project plugins |
| `strut status-all [--env <name>] [--json]` | Dashboard across all stacks |
| `strut upgrade` | Upgrade strut to latest version |
| `strut doctor [--check-vps] [--deep] [--json] [--fix]` | Diagnose common issues |
| `strut fleet status [--json]` | Show git sync state across all hosts |
| `strut completions <bash\|zsh\|fish>` | Print shell completion script |
| `strut skills list\|install [--format <fmt>]` | AI agent context management |

---

## Stack Commands

Usage: `strut <stack> <command> [options]`

### Deploy & Release

| Command | Description |
|---------|-------------|
| `deploy [--pull-only] [--skip-validation] [--blue-green] [--standard]` | Deploy stack containers |
| `release [--strict] [--confirm-data-move]` | Full VPS release (update + migrate + deploy) |
| `rebuild [--no-cache] [--pull] [--confirm-data-move]` | Build images on target + deploy |
| `ship [-m <msg>] [--no-commit] [--no-push] [--no-cache]` | Commit, push, rebuild on remote |
| `update` | Pull latest strut on VPS |
| `stop [--volumes]` | Stop running containers |
| `rollback` | Restore previous deploy snapshot |
| `prune` | Remove unused containers/images/volumes on VPS |

### Secrets & Env

| Command | Description |
|---------|-------------|
| `secrets push` | Upload .env to VPS |
| `secrets pull` | Download .env from VPS |
| `secrets diff` | Compare local vs remote key names (masked) |
| `secrets validate` | Check required_vars coverage |
| `secrets hydrate` | Populate .env from template + providers |
| `secrets status` | Show local/remote/template state |
| `secrets set <key> [--value <val>]` | Set a single secret |
| `secrets lock\|unlock` | Lock/unlock encrypted secrets |
| `secrets rotate` | Rotate all rotatable secrets |
| `secrets template` | Generate .env.template from .env |
| `secrets export` | Export secrets for CI/CD |
| `init-secrets [--force]` | Generate .env from template with auto-secrets |

### Database

| Command | Description |
|---------|-------------|
| `backup [postgres\|mysql\|sqlite\|neo4j\|all\|verify\|list\|health\|schedule\|retention]` | Backup management |
| `restore <file> [--target-env <env>] [--dry-run]` | Restore backup (--dry-run for rehearsal) |
| `db:pull [target] [--download-only] [--file <name>]` | Pull backup from VPS + restore locally |
| `db:push [target] [--upload-only] [--file <name>]` | Upload local backup to VPS + restore |
| `db:schema [apply\|verify\|all]` | Apply/verify Postgres schema SQL |
| `migrate [neo4j\|postgres] [--up\|--down N\|--status]` | Run schema migrations |

### Drift & Monitoring

| Command | Description |
|---------|-------------|
| `drift detect` | Detect configuration drift |
| `drift report [--json]` | Generate drift report |
| `drift images [--json] [--remote]` | Check for stale image digests |
| `drift fix [--dry-run]` | Fix detected drift |
| `drift monitor [--auto-fix]` | Monitor for drift (cron) |
| `drift history [--limit N]` | Show detection history |
| `drift auto-fix enable\|disable\|status` | Manage auto-fix |
| `diff [--json]` | Preview pending changes vs VPS |
| `health [--json]` | Run health checks |
| `status` | Stack status |
| `posture [--category <c>] [--fail-on <l>]` | Security/ops posture check |

### Infrastructure

| Command | Description |
|---------|-------------|
| `sync [<host>\|--all] [--dry-run]` | Bring host checkout in sync with origin |
| `remote:init [--host <h>] [--user <u>]` | Bootstrap strut on VPS |
| `gateway deploy\|status\|reload\|validate --host <alias>` | Caddy gateway management |
| `cert:renew [--host <alias>]` | Renew SSL/TLS certificates |
| `cert:status [--host <alias>]` | Show certificate status |
| `provision <host-alias> [--script <path>]` | Run provisioning scripts |
| `ssh:keygen` | Generate/rotate SSH deploy keys |
| `ci:init` | Bootstrap CI/CD integration |
| `domain <domain> <email> [--skip-ssl]` | Configure domain/SSL |

### Keys

| Command | Description |
|---------|-------------|
| `keys env:rotate [--dry-run] [--force]` | Rotate env secrets |
| `keys env:set <key> <value>` | Set env variable |
| `keys env:sync` | Sync .env from template |
| `keys env:validate` | Validate .env completeness |
| `keys env:diff --local <file> --remote` | Compare local vs remote env |
| `keys env:backup [--encrypt]` | Backup env file |
| `keys db:rotate <engine> [--dry-run] [--force]` | Rotate database passwords |
| `keys ssh:add <user> [--dry-run]` | Add SSH key |
| `keys ssh:revoke <user> [--force]` | Revoke SSH key |
| `keys ssh:rotate <user> [--dry-run] [--force]` | Rotate SSH key |
| `keys api:generate <name> [--force]` | Generate API key |
| `keys api:rotate <name>` | Rotate API key |
| `keys github:rotate-vps-key [--dry-run]` | Rotate GitHub deploy key |

### Other

| Command | Description |
|---------|-------------|
| `shell` | SSH to VPS |
| `exec <command>` | Execute command on VPS |
| `logs [service] [--since <dur>] [--follow]` | View logs |
| `logs:download [--since <dur>]` | Download logs from VPS |
| `logs:rotate` | Rotate container logs |
| `lock status\|release [--force]` | Inspect/manage deploy locks |
| `volumes [status\|init\|config]` | Volume management |
| `scaffold <name> [--recipe <name>]` | New stack from recipe |
| `monitoring <subcommand>` | Monitoring stack management |
| `notify <channel> <message>` | Send alert notification |

---

## New in v0.31.0

- `strut fleet status [--json]` — fleet-wide sync visibility
- `strut <stack> drift images [--json] [--remote]` — image-digest drift
- `strut <stack> restore <file> --dry-run` — non-destructive restore rehearsal
- `STRUT_SSH_HOST_KEY_CHECK` env variable — control SSH host key checking
- `deploy_dir=` in `[hosts]` specs — per-host deploy directory override
- `strut skills install <format>` — positional format argument

---

## Related

- [Configuration](https://github.com/gfargo/strut/wiki/Configuration) — strut.conf and env variables
- [What's New in v0.31.0](https://github.com/gfargo/strut/wiki/Whats-New-v0.31) — release highlights
- [Fleet Status](https://github.com/gfargo/strut/wiki/Fleet-Status) — fleet monitoring deep dive
- [Secrets Management](https://github.com/gfargo/strut/wiki/Secrets-Management) — hydration and providers
- [GitHub Action](https://github.com/gfargo/strut/wiki/GitHub-Action) — CI/CD integration
