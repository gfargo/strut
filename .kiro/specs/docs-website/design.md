# strut Marketing & Documentation Website — Design

#[[file:requirements.md]]

---

## Architecture

### Static Site with Astro Starlight

The site is a statically generated documentation site built with [Astro](https://astro.build) and the [Starlight](https://starlight.astro.build) docs theme. The marketing landing page is a custom Astro page that lives alongside the Starlight docs.

```
docs-site/
├── astro.config.mjs          # Astro + Starlight config
├── package.json
├── public/
│   ├── favicon.svg
│   └── og-image.png          # Open Graph preview image
├── src/
│   ├── assets/
│   │   └── logo.svg          # strut logo
│   ├── components/
│   │   ├── Hero.astro         # Landing page hero
│   │   ├── Features.astro     # Feature grid
│   │   ├── Comparison.astro   # strut vs. alternatives table
│   │   ├── InstallBlock.astro # Copyable install command
│   │   ├── Terminal.astro     # Terminal-style code display
│   │   └── Personas.astro     # "Who it's for" cards
│   ├── content/
│   │   └── docs/              # Starlight Markdown content
│   │       ├── index.mdx      # Docs landing (Getting Started)
│   │       ├── installation.md
│   │       ├── quickstart.md
│   │       ├── project-structure.md
│   │       ├── configuration/
│   │       │   ├── strut-conf.md
│   │       │   ├── services-conf.md
│   │       │   └── env-files.md
│   │       ├── commands/
│   │       │   ├── index.md    # Command reference overview
│   │       │   ├── deploy.md
│   │       │   ├── release.md
│   │       │   ├── stop.md
│   │       │   ├── health.md
│   │       │   ├── logs.md
│   │       │   ├── backup.md
│   │       │   ├── restore.md
│   │       │   ├── drift.md
│   │       │   ├── keys.md
│   │       │   ├── local.md
│   │       │   ├── debug.md
│   │       │   └── ...
│   │       ├── concepts/
│   │       │   ├── environments.md
│   │       │   ├── profiles.md
│   │       │   ├── health-checks.md
│   │       │   ├── backup-lifecycle.md
│   │       │   ├── drift-detection.md
│   │       │   └── key-management.md
│   │       └── recipes/
│   │           ├── first-deploy.md
│   │           ├── automated-backups.md
│   │           ├── secret-rotation.md
│   │           ├── migrate-existing.md
│   │           ├── ssl-domain.md
│   │           └── local-dev-sync.md
│   ├── pages/
│   │   └── index.astro        # Marketing landing page (custom, not Starlight)
│   └── styles/
│       └── landing.css        # Landing page styles
└── .github/
    └── workflows/
        └── deploy.yml         # Build + deploy to GitHub Pages
```

### Key Design Decisions

**Landing page is a custom Astro page, not a Starlight page.**
Starlight is optimized for docs layout (sidebar, TOC, etc.). The marketing landing page needs a different layout — full-width hero, feature grids, comparison tables. We use a standalone Astro page at `src/pages/index.astro` that links into the `/docs/` Starlight section.

**Docs content lives in Markdown.**
All documentation is authored in `.md` / `.mdx` files inside `src/content/docs/`. This keeps the docs-as-code workflow intact — contributors edit Markdown, not React components.

**Sidebar navigation is defined in `astro.config.mjs`.**
Starlight's sidebar config is declarative. Groups and ordering are controlled in one place rather than scattered across frontmatter.

**No CMS, no database.**
Everything is in the repo. Content changes go through PRs like code changes.

---

## Landing Page Design

### Layout (top to bottom)

1. **Nav bar** — Logo, "Docs" link, "GitHub" link, dark/light toggle
2. **Hero** — Tagline, subtitle, install command block, "Read the Docs" CTA button
3. **Terminal demo** — Static or animated terminal showing `strut init` → `strut scaffold` → `strut deploy` workflow
4. **Feature grid** — 6-8 cards with icons, each highlighting a core capability
5. **Comparison table** — strut vs. Kubernetes vs. Kamal vs. manual scripts (columns: complexity, learning curve, time to first deploy, multi-stack, backup/restore, drift detection)
6. **Personas** — 3 cards: solo dev, small team, agency
7. **Footer** — GitHub link, docs link, version, license

### Visual Direction

- Dark background by default (matches terminal aesthetic)
- Monospace font for code, clean sans-serif for body text
- Accent color: a muted blue or teal (echoing the `BLUE` color used in strut's terminal output)
- Minimal illustrations — let the terminal output and code blocks do the talking
- No stock photos, no abstract gradients

### Hero Copy (draft)

> **Deploy Docker stacks without the drama.**
>
> strut is a CLI tool for managing Docker stacks on VPS infrastructure. One command to deploy, backup, monitor, and operate — no Kubernetes, no YAML sprawl, no vendor lock-in.
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/gfargo/strut/main/install.sh | bash
> ```

---

## Documentation Structure

### Sidebar Navigation

```
Getting Started
  ├── Installation
  ├── Quick Start
  └── Project Structure

Configuration
  ├── strut.conf
  ├── services.conf
  └── Environment Files

Commands
  ├── Overview
  ├── Deployment
  │   ├── release
  │   ├── deploy
  │   ├── stop
  │   └── update
  ├── Observability
  │   ├── health
  │   ├── logs
  │   └── status
  ├── Database
  │   ├── backup
  │   ├── restore
  │   ├── db:pull
  │   ├── db:push
  │   ├── db:schema
  │   └── migrate
  ├── Infrastructure
  │   ├── drift
  │   ├── keys
  │   ├── volumes
  │   ├── domain
  │   └── monitoring
  ├── Development
  │   ├── local
  │   └── debug
  └── Project
      ├── init
      ├── scaffold
      ├── list
      └── audit

Concepts
  ├── Environments
  ├── Service Profiles
  ├── Health Checks
  ├── Backup Lifecycle
  ├── Drift Detection
  └── Key Management

Recipes
  ├── First Deploy to a VPS
  ├── Automated Backups
  ├── Secret Rotation
  ├── Migrate Existing Setup
  ├── SSL & Custom Domain
  └── Local Dev Sync
```

### Command Reference Page Template

Each command page follows a consistent structure:

```markdown
---
title: deploy
description: Deploy a stack to local or VPS environment
---

## Usage

\`\`\`bash
strut <stack> deploy [--env <name>] [--services <profile>] [--pull-only]
\`\`\`

## Description

Deploys the specified stack by pulling images and running docker compose up.
Runs locally by default, or on VPS if `VPS_HOST` is set in the env file.

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--env <name>` | Environment name (reads `.<name>.env`) | `.env` |
| `--services <profile>` | Service profile | core only |
| `--pull-only` | Pull images without starting containers | false |
| `--dry-run` | Preview without executing | false |

## Examples

\`\`\`bash
# Deploy to production
strut my-app deploy --env prod

# Deploy all services
strut my-app deploy --env prod --services full

# Pull images only (useful for pre-staging)
strut my-app deploy --env prod --pull-only
\`\`\`

## Runs Where

Local or VPS (depends on `VPS_HOST` in env file)

## See Also

- [release](/docs/commands/release/) — Full VPS release workflow
- [stop](/docs/commands/stop/) — Stop running containers
- [health](/docs/commands/health/) — Verify deployment health
```

---

## Build & Deploy

### GitHub Actions Workflow

```yaml
name: Deploy Docs
on:
  push:
    branches: [main]
    paths:
      - 'docs-site/**'
      - '.github/workflows/deploy-docs.yml'

jobs:
  build-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
        working-directory: docs-site
      - run: npm run build
        working-directory: docs-site
      - uses: actions/upload-pages-artifact@v3
        with:
          path: docs-site/dist
      - uses: actions/deploy-pages@v4
```

### Local Development

```bash
cd docs-site
npm install
npm run dev     # http://localhost:4321
```

---

## Implementation Phases

### Phase 1: Foundation (MVP)
- [ ] Astro + Starlight project setup
- [ ] Landing page with hero, install block, and feature grid
- [ ] Getting Started docs (installation, quickstart, project structure)
- [ ] Configuration reference (strut.conf, services.conf, env files)
- [ ] GitHub Actions deploy pipeline
- [ ] Dark mode default + light toggle

### Phase 2: Full CLI Reference
- [ ] Command reference pages for all commands
- [ ] Sidebar navigation with grouped commands
- [ ] Consistent command page template
- [ ] Search integration (Pagefind)

### Phase 3: Concepts & Recipes
- [ ] Concept guide pages
- [ ] Recipe/cookbook pages
- [ ] Comparison table on landing page
- [ ] Persona cards on landing page

### Phase 4: Polish
- [ ] Open Graph image and meta tags
- [ ] "Edit on GitHub" links
- [ ] Version badge from `VERSION` file
- [ ] Sitemap generation
- [ ] Lighthouse audit and performance tuning
- [ ] Custom domain setup
