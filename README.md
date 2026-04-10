# strut

Generic, installable CLI tool for managing Docker stacks on VPS infrastructure. Deploy, monitor, and operate any number of stacks from a single command line.

---

## Install

```bash
# Clone and add to PATH
git clone <your-repo-url> ~/.strut
export PATH="$HOME/.strut:$PATH"

# Or use the installer
curl -fsSL https://raw.githubusercontent.com/<org>/strut/main/install.sh | bash
```

## Quick Start

```bash
# Initialize a new project
strut init --registry ghcr --org my-org

# Scaffold your first stack
strut scaffold my-app

# Edit your stack config
nano stacks/my-app/.env.template    # copy to .prod.env, fill secrets
nano stacks/my-app/services.conf    # declare services and ports
nano stacks/my-app/docker-compose.yml

# Deploy
strut my-app deploy --env prod

# Full VPS release (update repo + migrate + deploy + verify)
strut my-app release --env prod
```

---

## CLI

```
strut <stack> <command> [--env <env>] [options]
```

| Command | Description | Runs Where |
|---|---|---|
| `release [--services <profile>]` | Full VPS deployment (update + migrate + deploy + verify) | VPS (remote) |
| `deploy [--services <profile>] [--pull-only]` | Deploy stack | Local or VPS |
| `stop [--volumes] [--timeout N]` | Stop running containers | Local or VPS |
| `update` | Pull latest strut code on VPS | VPS (remote) |
| `health [--json]` | Run health checks | Local or VPS |
| `logs [service] [--follow] [--since <dur>]` | View service logs | Local or VPS |
| `migrate [neo4j\|postgres] [--status\|--up\|--down N]` | Run database migrations | Local or VPS |
| `backup [postgres\|neo4j\|mysql\|sqlite\|all]` | Create backups | Local or VPS |
| `restore <file>` | Restore from backup | Local or VPS |
| `db:pull [type] [--download-only]` | Pull backup from VPS, restore locally | VPS → Local |
| `db:push [type] [--upload-only] [--file <name>]` | Push local backup to VPS | Local → VPS |
| `drift [detect\|report\|fix\|auto-fix]` | Configuration drift detection | Local or VPS |
| `keys <subcommand>` | Key management (SSH, API, env, db, GitHub) | Local or VPS |
| `volumes [status\|init\|config]` | Volume management | Local or VPS |
| `shell` | SSH to VPS | VPS (remote) |
| `exec <command>` | Execute command on VPS | VPS (remote) |
| `status` | Show container status | Local or VPS |
| `domain <domain> <email> [--skip-ssl]` | Configure domain and SSL | VPS (remote) |
| `list` | List all available stacks | Local |
| `scaffold <name>` | Create new stack from templates | Local |
| `init [--registry <type>] [--org <name>]` | Initialize new project | Local |
| `upgrade` | Upgrade strut to latest version | Local |
| `--version` | Show installed version | Local |

### Examples

```bash
# VPS production release (recommended one-command workflow)
strut my-app release --env prod

# Manual VPS steps
strut my-app update --env prod
strut my-app deploy --env prod
strut my-app health --env prod --json

# Stop containers
strut my-app stop --env prod
strut my-app stop --env prod --volumes    # also remove volumes

# Local development
strut my-app deploy --env prod
strut my-app deploy --env prod --services full

# Logs and monitoring
strut my-app logs my-service --follow --env prod
strut my-app health --env prod --json
strut my-app status --env prod

# Database operations
strut my-app backup postgres --env prod
strut my-app db:pull --env prod
strut my-app db:push postgres --env prod --file backups/postgres-20260303.sql

# Key management
strut my-app keys discover
strut my-app keys ssh:add alice --generate
strut my-app keys db:rotate postgres

# Domain and SSL
strut my-app domain api.example.com admin@example.com --env prod

# Stack management
strut list
strut scaffold my-new-stack
```

---

## Project Structure

A strut project has two parts: the engine (installed at `~/.strut`) and your project directory.

### Engine (Strut_Home)

```
~/.strut/
├── strut              # CLI entrypoint
├── VERSION
├── install.sh
├── lib/               # Shell library modules
│   ├── config.sh      # Project config discovery
│   ├── registry.sh    # Pluggable registry auth
│   ├── utils.sh       # Colors, logging, helpers
│   ├── deploy.sh      # Deploy orchestration
│   ├── health.sh      # Dynamic health checks
│   ├── docker.sh      # Docker helpers
│   ├── backup.sh      # Backup/restore
│   ├── volumes.sh     # Volume management
│   ├── keys.sh        # Key management
│   └── cmd_*.sh       # Command handlers
└── templates/         # Stack scaffolding templates
```

### Your Project (Project_Root)

```
my-project/
├── strut.conf         # Project-level config
├── .gitignore
└── stacks/
    └── my-app/
        ├── docker-compose.yml
        ├── docker-compose.dev.yml
        ├── .env.template
        ├── services.conf      # Service ports, health paths, DB flags
        ├── required_vars      # Required env vars for validation
        ├── volume.conf        # Volume path mappings
        ├── repos.conf         # GitHub repos for key management
        ├── backup.conf        # Backup schedule config
        ├── nginx/
        └── sql/init/
```

---

## Configuration

### strut.conf

Project-level settings at the root of your project:

```bash
# Container registry: ghcr | dockerhub | ecr | none
REGISTRY_TYPE=ghcr

# Default GitHub/registry organization
DEFAULT_ORG=my-org

# Default git branch for VPS repo sync
DEFAULT_BRANCH=main

# Banner text in deploy/release output
BANNER_TEXT=my-project
```

### services.conf

Per-stack service declarations for dynamic health checking:

```bash
# Application services
API_PORT=8000
API_HEALTH_PATH=/health

WORKER_PORT=8001

# Database flags
DB_POSTGRES=true
DB_REDIS=true
```

---

## Key Concepts

- `deploy` runs locally on your machine (or on the VPS if you're SSH'd in)
- `release` runs remotely on the VPS via SSH — it's the recommended production workflow
- `stop` stops containers locally or remotely depending on whether VPS_HOST is set
- `--env prod` reads `.prod.env` for secrets and VPS connection info
- `--dry-run` previews destructive operations without executing them
- Health checks, service discovery, and database probes are all driven by `services.conf`
- No hardcoded service names, ports, or org references in the engine

---

## Testing

```bash
# Run all tests
bats tests/

# Run specific test file
bats tests/test_config.bats
bats tests/test_init.bats
```

---

## License

See LICENSE file.
