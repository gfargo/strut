# strut

Generic, installable CLI tool for managing Docker stacks on VPS infrastructure. Deploy, monitor, and operate any number of stacks from a single command line.

📖 **[Full Documentation →](https://github.com/gfargo/strut/wiki)**

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gfargo/strut/main/install.sh | bash
```

Or clone manually:

```bash
git clone https://github.com/gfargo/strut.git ~/.strut
export PATH="$HOME/.strut:$PATH"
```

See [Installation](https://github.com/gfargo/strut/wiki/Installation) for upgrade, uninstall, and configuration options.

## Quick Start

```bash
strut init --registry ghcr --org my-org       # Initialize project
strut scaffold my-app                          # Create a stack
nano stacks/my-app/.env.template               # Configure (copy to .prod.env)
strut my-app release --env prod                # Deploy to VPS
```

See [Quick Start](https://github.com/gfargo/strut/wiki/Quick-Start) for the full walkthrough.

---

## CLI

```text
strut <stack> <command> [--env <env>] [options]
```

| Command | Description |
| ------- | ----------- |
| `release` | Full VPS release (update + migrate + deploy + verify) |
| `deploy` | Deploy stack containers |
| `stop` | Stop running containers |
| `health` | Run health checks |
| `logs` | View service logs |
| `backup` / `restore` | Database backup and restore |
| `db:pull` / `db:push` | Sync databases between VPS and local |
| `drift` | Configuration drift detection and auto-fix |
| `keys` | Key and credential management |
| `domain` | Configure domain and SSL certificates |
| `shell` / `exec` | SSH access to VPS |
| `local` | Local development environment |
| `debug` | Container debugging tools |
| `list` / `scaffold` / `init` | Stack and project management |

See [CLI Reference](https://github.com/gfargo/strut/wiki/CLI-Reference) for the complete command list with flags and examples.

### Examples

```bash
strut my-app release --env prod                              # Production release
strut my-app health --env prod --json                        # Health checks
strut my-app logs api --follow --env prod                    # Follow logs
strut my-app backup postgres --env prod                      # Backup database
strut my-app db:pull --env prod                              # Pull DB locally
strut my-app keys db:rotate postgres --env prod              # Rotate credentials
strut my-app domain api.example.com admin@example.com --env prod  # SSL setup
```

---

## Key Concepts

- **Two-tree architecture** — engine at `~/.strut/`, your config at project root ([Architecture](https://github.com/gfargo/strut/wiki/Architecture))
- **Config-driven** — no hardcoded service names, ports, or orgs in the engine ([Configuration](https://github.com/gfargo/strut/wiki/Configuration))
- **`release` vs `deploy`** — `release` runs on VPS via SSH, `deploy` runs locally
- **`--env prod`** reads `.prod.env` for secrets and VPS connection info
- **`--dry-run`** previews destructive operations without executing
- **Dynamic health checks** driven by `services.conf`

---

## Documentation

| Topic | Description |
| ----- | ----------- |
| [Installation](https://github.com/gfargo/strut/wiki/Installation) | Install, upgrade, uninstall |
| [Quick Start](https://github.com/gfargo/strut/wiki/Quick-Start) | First project walkthrough |
| [Architecture](https://github.com/gfargo/strut/wiki/Architecture) | How strut works under the hood |
| [Configuration](https://github.com/gfargo/strut/wiki/Configuration) | `strut.conf`, env files, per-stack config |
| [CLI Reference](https://github.com/gfargo/strut/wiki/CLI-Reference) | Full command reference |
| [Deployment](https://github.com/gfargo/strut/wiki/Deployment) | Deploy, release, stop workflows |
| [Database Backups](https://github.com/gfargo/strut/wiki/Database-Backups) | Backup, restore, pull, push |
| [Key Rotation](https://github.com/gfargo/strut/wiki/Key-Rotation) | SSH, API, DB, GitHub credential rotation |
| [Drift Detection](https://github.com/gfargo/strut/wiki/Drift-Detection) | Detect and fix config drift |
| [Domain and SSL](https://github.com/gfargo/strut/wiki/Domain-and-SSL) | Custom domains, Let's Encrypt |
| [Monitoring](https://github.com/gfargo/strut/wiki/Monitoring) | Prometheus, Grafana, Alertmanager |
| [Volume Management](https://github.com/gfargo/strut/wiki/Volume-Management) | Dynamic volume management |
| [VPS Audit & Migration](https://github.com/gfargo/strut/wiki/VPS-Audit-and-Migration) | Audit and migrate existing setups |
| [Stack Validation](https://github.com/gfargo/strut/wiki/Stack-Validation) | Validate stack integrity |
| [Debugging](https://github.com/gfargo/strut/wiki/Debugging) | Troubleshoot production issues |
| [Local Development](https://github.com/gfargo/strut/wiki/Local-Development) | Local stack management |
| [Contributing](https://github.com/gfargo/strut/wiki/Contributing) | Setup, testing, linting |
| [Code Conventions](https://github.com/gfargo/strut/wiki/Code-Conventions) | Shell module standards |
| [Adding a New Command](https://github.com/gfargo/strut/wiki/Adding-a-New-Command) | Extending the CLI |
| [Project Structure](https://github.com/gfargo/strut/wiki/Project-Structure) | File layout and module map |

---

## Testing

```bash
bats tests/                    # Run all tests
bats tests/test_config.bats    # Run specific file
```

See [Contributing](https://github.com/gfargo/strut/wiki/Contributing) for the full development setup.

## License

See [LICENSE](LICENSE) file.
