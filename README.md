<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-mark-light.svg">
  <source media="(prefers-color-scheme: light)" srcset=".github/assets/logo-mark-dark.svg">
  <img alt="strut" src=".github/assets/logo-mark-dark.svg" width="120">
</picture>

# strut

**A Bash CLI that deploys Docker Compose stacks to any VPS over SSH.**

No agents, no daemons, no vendor lock-in — just a config-driven engine that treats your VPS like a deploy target instead of a pet.

[![Tests](https://img.shields.io/github/actions/workflow/status/gfargo/strut/test.yml?branch=main&label=tests&style=flat-square)](https://github.com/gfargo/strut/actions/workflows/test.yml)
[![Integration](https://img.shields.io/github/actions/workflow/status/gfargo/strut/integration.yml?branch=main&label=integration&style=flat-square)](https://github.com/gfargo/strut/actions/workflows/integration.yml)
[![ShellCheck](https://img.shields.io/github/actions/workflow/status/gfargo/strut/lint.yml?branch=main&label=shellcheck&style=flat-square)](https://github.com/gfargo/strut/actions/workflows/lint.yml)
[![Release](https://img.shields.io/github/v/release/gfargo/strut?style=flat-square&label=release&color=00c853)](https://github.com/gfargo/strut/releases/latest)
[![License: MIT](https://img.shields.io/github/license/gfargo/strut?style=flat-square)](LICENSE)
[![Stars](https://img.shields.io/github/stars/gfargo/strut?style=flat-square)](https://github.com/gfargo/strut/stargazers)

[**Website**](https://strut.griffen.codes) · [**Wiki**](https://github.com/gfargo/strut/wiki) · [**CLI Reference**](https://github.com/gfargo/strut/wiki/CLI-Reference) · [**Changelog**](https://github.com/gfargo/strut/releases)

<img src="https://strut.griffen.codes/demos/gif/hero-deploy.gif" alt="strut init, scaffold, and release in three commands" width="720" />

</div>

---

## Why strut

Most deploy tooling makes you choose between "too simple to trust in production" and "too much platform to run yourself." strut is the middle path: a single Bash entrypoint plus a handful of `lib/*.sh` modules that turn `docker compose` + SSH into a real deployment workflow, without asking you to adopt a platform.

- 🚀 **Zero-downtime blue-green deploys** — dual-project swap, health-gated, automatic rollback on failure
- 🩺 **Dynamic health checks** — discovered from `services.conf`, no hardcoded service names or ports
- 🗄️ **Database lifecycle** — backup, restore, verify, and rehearse restores for Postgres, Neo4j, MySQL, and SQLite
- 🔍 **Drift detection** — catches config drift *and* stale image digests on mutable tags, with optional auto-fix
- 🔑 **Key rotation** — SSH, API, DB, and GitHub credentials, rotated and redeployed in one command
- 🌐 **Domain & SSL** — Let's Encrypt via nginx or Caddy, manual or auto-provisioned on deploy
- 🖥️ **Multi-host fleets** — one `strut.conf` maps stacks to hosts; `strut fleet status` reports drift across all of them
- 🤖 **MCP server + webhooks** — expose strut as MCP tools for AI agents, or wire up push-to-deploy
- 📦 **Config-driven engine** — the `~/.strut/` engine ships no service names, ports, or org names; everything lives in *your* `strut.conf`

Everything is plain Bash (`set -euo pipefail`, no runtime deps beyond `docker`, `ssh`, and coreutils) and covered by a BATS test suite with property-based tests.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gfargo/strut/main/install.sh | bash
```

Or clone manually:

```bash
git clone https://github.com/gfargo/strut.git ~/.strut
export PATH="$HOME/.strut:$PATH"
```

Already installed? `strut upgrade` pulls the latest release in place.

See [Installation](https://github.com/gfargo/strut/wiki/Installation) for upgrade, uninstall, and configuration options.

## Quick Start

```bash
strut init --registry ghcr --org my-org       # Initialize project
strut scaffold my-app                          # Create a stack
nano stacks/my-app/.env.template               # Configure (copy to .prod.env)
strut my-app release --env prod                # Deploy to VPS
```

No arguments launches an interactive TUI (`fzf`-powered) for picking a stack and command:

```bash
strut
```

See [Quick Start](https://github.com/gfargo/strut/wiki/Quick-Start) for the full walkthrough.

---

## See it in action

Real terminal recordings — the actual strut CLI, scripted output.

<table>
<tr>
<td width="50%">

**Ship** — commit, push, rebuild on remote in one shot
<img src="https://strut.griffen.codes/demos/gif/ship.gif" alt="strut ship demo" width="360" />

</td>
<td width="50%">

**Rollback** — instant recovery when a health check fails
<img src="https://strut.griffen.codes/demos/gif/rollback.gif" alt="strut rollback demo" width="360" />

</td>
</tr>
<tr>
<td width="50%">

**Drift** — detect and fix config drift automatically
<img src="https://strut.griffen.codes/demos/gif/drift-detect.gif" alt="strut drift detect demo" width="360" />

</td>
<td width="50%">

**Backup** — reliable backups with verification
<img src="https://strut.griffen.codes/demos/gif/backup-restore.gif" alt="strut backup and restore demo" width="360" />

</td>
</tr>
</table>

More demos — including recordings against a real DigitalOcean droplet — on the [website](https://strut.griffen.codes/#demos).

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
| `ship` | Commit, push, and remote rebuild in one step |
| `remote:init` | Bootstrap strut on a remote VPS |
| `local` | Local development environment |
| `debug` | Container debugging tools |
| `fleet` | Multi-host status and sync |
| `dashboard` | Read-only HTTP fleet status page (HTML + JSON) |
| `mcp` | Expose strut as an MCP server for AI agents |
| `webhook` | Push-to-deploy via polling or an HTTP receiver |
| `list` / `scaffold` / `init` | Stack and project management |

See [CLI Reference](https://github.com/gfargo/strut/wiki/CLI-Reference) for the complete command list with flags and examples.

### Examples

```bash
strut my-app release --env prod                              # Production release
strut my-app health --env prod --json                        # Health checks
strut my-app logs api --follow --env prod                    # Follow logs
strut my-app backup postgres --env prod                      # Backup database
strut my-app restore backups/postgres-20260701.sql --env prod --dry-run  # Rehearse a restore
strut my-app db:pull --env prod                               # Pull DB locally
strut my-app drift images --env prod                          # Check for stale image digests
strut my-app keys db:rotate postgres --env prod               # Rotate credentials
strut my-app domain api.example.com admin@example.com --env prod  # SSL setup
strut fleet status                                             # Git sync state across all hosts
strut dashboard --port 8484                                    # Read-only HTTP fleet status page
```

---

## Key Concepts

- **Two-tree architecture** — engine at `~/.strut/`, your config at project root ([Architecture](https://github.com/gfargo/strut/wiki/Architecture))
- **Config-driven** — no hardcoded service names, ports, or orgs in the engine ([Configuration](https://github.com/gfargo/strut/wiki/Configuration))
- **`release` vs `deploy`** — `release` runs on VPS via SSH, `deploy` runs locally
- **`--env prod`** reads `.prod.env` for secrets and VPS connection info
- **Per-stack env isolation** — `.prod.env` is shared by every stack deployed with `--env prod` on a host. If it sets `COMPOSE_PROJECT_NAME`, *all* those stacks resolve to the same Compose project, so a deploy's orphan cleanup can delete a sibling stack's containers. To isolate a stack, give it its own env file (`.<stack>-prod.env`) and deploy with `--env <stack>-prod`; run `strut posture` to catch this footgun before it bites
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
| [Blue-Green Deploy](https://github.com/gfargo/strut/wiki/Blue-Green-Deploy) | Zero-downtime dual-project deploys |
| [Database Backups](https://github.com/gfargo/strut/wiki/Database-Backups) | Backup, restore, restore rehearsal, pull, push |
| [Key Rotation](https://github.com/gfargo/strut/wiki/Key-Rotation) | SSH, API, DB, GitHub credential rotation |
| [Drift Detection](https://github.com/gfargo/strut/wiki/Drift-Detection) | Detect and fix config and image-digest drift |
| [Domain and SSL](https://github.com/gfargo/strut/wiki/Domain-and-SSL) | Custom domains, Let's Encrypt, auto-provisioning |
| [Multi-Host Topology](https://github.com/gfargo/strut/wiki/Multi-Host-Topology) | Map stacks to hosts, fleet status |
| [MCP Server](https://github.com/gfargo/strut/wiki/MCP-Server) | Expose strut operations as MCP tools |
| [Webhook Automation](https://github.com/gfargo/strut/wiki/Webhook-Automation) | Push-to-deploy via poll or receiver |
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

## GitHub Action / CI Deploys

Deploy a strut-managed stack from GitHub Actions in one step:

```yaml
- uses: actions/checkout@v4

- uses: gfargo/strut-action@v1
  with:
    stack: my-app
    command: release          # release | ship (see security note in wiki)
    env: prod
    host: ${{ secrets.STRUT_HOST }}
    ssh-key: ${{ secrets.STRUT_SSH_KEY }}
```

The action installs a pinned strut, writes the SSH key to a `600`-permissions file, materializes the env file from inputs/secrets, and runs the requested command. SSH key and env values are never echoed to logs.

See [GitHub Action](https://github.com/gfargo/strut/wiki/GitHub-Action) for the full input reference, pinning instructions, and examples. A starter workflow is available in [`templates/.github/workflows/strut-deploy.yml`](templates/.github/workflows/strut-deploy.yml).

## Known Limitations

**Project paths must not contain spaces.** strut's compose and SSH command
builders use word-split path expansion internally, so a project root like
`/Users/me/My Projects/infra` is rejected up front with a clear error rather
than failing confusingly deep in the pipeline.

Workarounds:
- Create a space-free symlink: `ln -s "/path/with spaces/infra" ~/strut-project`
- Or set `STRUT_PROJECT` to the symlink: `STRUT_PROJECT=~/strut-project strut <stack> <cmd>`

---

## Testing

```bash
bats tests/                    # Run all tests
bats tests/test_config.bats    # Run specific file
```

See [Contributing](https://github.com/gfargo/strut/wiki/Contributing) for the full development setup.

## Contributing

Issues and PRs welcome — see [Contributing](https://github.com/gfargo/strut/wiki/Contributing) and [Code Conventions](https://github.com/gfargo/strut/wiki/Code-Conventions) for setup, testing, and shell style guidelines.

## License

MIT — see [LICENSE](LICENSE).
