# strut — Developer Context

Generic CLI tool for managing Docker stacks on VPS infrastructure. Bash + BATS test suite.

## Architecture

Two filesystem trees collaborate at runtime:

- **Strut_Home** (`~/.strut/`) — the engine: `strut` entrypoint, `lib/*.sh` modules, `templates/`
- **Project_Root** (user's dir) — their config: `strut.conf`, `stacks/`, `.env` files

The `strut` entrypoint resolves Strut_Home via symlink resolution, then walks up from `$PWD` to find `strut.conf` (Project_Root). Config is loaded before any lib modules.

## Key Files

| File | Purpose |
|------|---------|
| `strut` | CLI entrypoint — command dispatch, usage |
| `lib/config.sh` | Project config discovery (`find_project_root`, `load_strut_config`) |
| `lib/registry.sh` | Pluggable registry auth (ghcr/dockerhub/ecr/none) |
| `lib/utils.sh` | Colors, logging, SSH helpers, compose builders |
| `lib/deploy.sh` | Deploy orchestration, VPS release, repo sync |
| `lib/health.sh` | Dynamic health checks from `services.conf` |
| `lib/cmd_*.sh` | Command handlers (deploy, stop, init, scaffold, tui, etc.) |
| `lib/docker.sh` | Docker pull, prune helpers |
| `lib/volumes.sh` | Dynamic volume management from `volume.conf` |
| `lib/keys.sh` + `lib/keys/` | Key management (SSH, API, env, db, GitHub) |
| `lib/backup.sh` + `lib/backup/` | Backup/restore for Postgres, Neo4j, MySQL, SQLite |
| `lib/drift.sh` + `lib/drift/` | Config drift detection and auto-fix |
| `lib/migrate.sh` + `lib/migrate/` | VPS migration wizard (8 phases) |
| `templates/` | Scaffold templates for new stacks |
| `install.sh` | One-liner installer (clone + symlink) |
| `VERSION` | Semver, read by `strut --version` |

## Commands

```
strut <stack> <command> [--env <name>] [--dry-run] [--services <profile>]
strut                                             # interactive TUI (fzf+select)
strut --no-tui | STRUT_NO_TUI=1                   # disable TUI

Top-level:  init, upgrade, --version, list, scaffold, audit, migrate, monitoring
Per-stack:  deploy, stop, release, update, health, logs, status, shell, exec,
            backup, restore, db:pull, db:push, db:schema, drift, volumes, keys, domain
```

## Config Files (per-stack, user-owned)

- `strut.conf` — project-level: registry type, org, branch, banner
- `services.conf` — service ports, health paths, DB flags (drives health engine)
- `required_vars` — env vars validated before deploy
- `volume.conf` — volume paths and ownership mappings
- `repos.conf` — GitHub repos for key management
- `backup.conf` — backup schedule and retention

## Design Principles

- No hardcoded service names, ports, orgs, or paths in the engine
- All behavior driven by config files (`strut.conf`, `services.conf`, etc.)
- `lib/config.sh` owns all config loading and defaults
- `lib/registry.sh` owns all registry auth dispatch
- Health checks dynamically discover services from `services.conf`
- Required vars validation is optional (skip if no `required_vars` file)

## Testing

```bash
bats tests/                    # Run all tests
bats tests/test_config.bats    # Run specific file
```

BATS test suite with property-based tests (100-iteration randomized loops). Key test files:

| Test | Properties |
|------|-----------|
| `test_config.bats` | Config walk-up, parsing defaults, symlink resolution |
| `test_registry.bats` | Registry dispatch routing, invalid type rejection |
| `test_health_discovery.bats` | Service/DB/port discovery from services.conf |
| `test_init.bats` | Init flag propagation to strut.conf |
| `test_entrypoint.bats` | Version round-trip, upgrade guard |
| `test_no_hardcodes.bats` | Static grep — no Climate-Hub references in engine |
| `test_scaffold.bats` | Org substitution, required_vars consistency |

## Conventions

- All `lib/*.sh` files start with `set -euo pipefail`
- `fail()` exits with code 1 to stderr; `warn()` continues to stdout
- `log()` prefix is `[strut]`; banner reads `BANNER_TEXT` from config
- SSH commands use `build_ssh_opts` for consistent option building
- Compose commands use `resolve_compose_cmd` for consistent project naming
- `DRY_RUN=true` + `run_cmd`/`run_cmd_eval` for preview mode

## Commit Messages

- **Do not** add `Co-Authored-By: Claude …` (or any AI/tool attribution) trailers to commits or PR bodies in this repo. History was filter-repo'd to remove them; don't reintroduce.

## Skills (`.kiro/skills/`)

9 procedural skills for operational workflows: `vps-deployment`, `vps-debugging`, `database-backups`, `key-rotation`, `stack-validation`, `drift-detection`, `monitoring-setup`, `domain-ssl`, `vps-audit-migration`.
