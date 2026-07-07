# strut Skills

A single [Agent Skills](https://agentskills.io/specification)-compliant skill (`strut/`) covering all strut VPS stack management operations.

The skill uses progressive disclosure: `strut/SKILL.md` is a lean router with a command quick-reference, and detailed procedures live in `strut/references/`:

| Reference | Covers |
| --- | --- |
| `references/deployment.md` | Deploying, releasing, updating, stopping services |
| `references/debugging.md` | Diagnosing production issues, logs, container status |
| `references/backups.md` | Database backup, restore, rehearsal, prod-data sync |
| `references/drift.md` | Config + image drift detection and auto-fix |
| `references/secrets.md` | Rotating SSH/API keys, DB passwords, env secrets |
| `references/monitoring.md` | Prometheus/Grafana/Alertmanager setup and alerts |
| `references/domains-ssl.md` | Custom domains and Let's Encrypt SSL |
| `references/validation.md` | Validating stack structure and config |
| `references/migration.md` | Auditing a VPS and migrating to strut |

Install into a project with `strut skills install` (Kiro) or `strut skills install --format claude` (Claude Code, etc.).

See `CLAUDE.md` at the project root for the full developer context and CLI reference.
