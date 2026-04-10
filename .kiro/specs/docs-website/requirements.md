# strut Marketing & Documentation Website — Requirements

## Overview

A public-facing website for strut that serves two purposes: marketing the tool to potential users (DevOps engineers, indie hackers, small teams managing VPS infrastructure) and providing comprehensive documentation for existing users.

The site should feel like the tool itself — no-nonsense, developer-friendly, and fast.

## Target Audience

1. **Primary:** Solo developers and small teams deploying Docker stacks to VPS servers who are tired of complex orchestration tools (Kubernetes, Terraform) for simple setups.
2. **Secondary:** DevOps engineers looking for a lightweight, scriptable alternative to heavier infrastructure tooling.
3. **Tertiary:** Open-source contributors evaluating the project.

## Goals

- Communicate what strut is in under 10 seconds of landing on the site
- Get a developer from "what is this?" to `curl | bash` install in under 60 seconds
- Provide searchable, well-organized reference docs for every command and concept
- Showcase real workflows (not just API surface)
- Be maintainable by the same team that maintains the CLI (minimal CMS overhead)

## Non-Goals

- User accounts, dashboards, or SaaS features
- Blog (can be added later, but not in v1)
- Pricing pages or commercial tiers
- Community forum (GitHub Discussions is sufficient)

---

## Functional Requirements

### FR-1: Landing / Marketing Page

The homepage should immediately communicate the value proposition.

**FR-1.1:** Hero section with a one-liner tagline, a brief description (2-3 sentences), and the install command in a copyable code block.

**FR-1.2:** "How it works" section showing the 3-step workflow: `init` → `scaffold` → `deploy`, with terminal-style animations or static code blocks.

**FR-1.3:** Feature highlights section covering the core capabilities:
- Multi-stack management from a single CLI
- One-command production releases (`strut my-app release --env prod`)
- Database backup/restore/sync across environments
- Configuration drift detection and auto-fix
- Key and secret rotation
- Dynamic health checks driven by `services.conf`
- Dry-run mode for safe operations
- VPS audit and migration wizard

**FR-1.4:** Comparison section — a concise table or visual showing strut vs. Kubernetes, Docker Swarm, Kamal, and manual SSH scripts. Focus on simplicity and time-to-deploy.

**FR-1.5:** "Who it's for" section with 2-3 persona cards (solo dev, small team, agency managing client VPS).

**FR-1.6:** Footer with links to GitHub repo, docs, install command, and version badge.

### FR-2: Documentation

**FR-2.1: Getting Started Guide**
- Prerequisites (bash, git, Docker, Docker Compose)
- Installation (clone + PATH, or `curl | bash` installer)
- Initializing a project (`strut init`)
- Scaffolding a stack (`strut scaffold`)
- First deploy walkthrough
- Project structure explanation

**FR-2.2: CLI Reference**
Auto-generated or manually maintained reference for every command. Each entry should include:
- Command signature and syntax
- Description
- Available flags and options
- Where it runs (local vs. VPS)
- Examples
- Related commands

Commands to document (grouped):

*Deployment & Lifecycle:*
- `release`, `deploy`, `stop`, `update`, `upgrade`

*Observability:*
- `health`, `logs`, `status`

*Database Operations:*
- `backup`, `restore`, `db:pull`, `db:push`, `db:schema`, `migrate`

*Infrastructure:*
- `drift`, `keys`, `volumes`, `domain`, `monitoring`

*Development:*
- `local` (start, stop, reset, sync-env, sync-db, logs, test)
- `debug` (exec, shell, port-forward, copy, snapshot, inspect-env, stats)

*Project Management:*
- `init`, `scaffold`, `list`, `audit`, `audit:generate`, `migrate` (wizard)

**FR-2.3: Configuration Reference**
- `strut.conf` — all keys, defaults, and descriptions
- `services.conf` — service declaration format, health check config, DB flags
- `.env` files — environment file conventions, per-env naming
- `required_vars` — validation file format
- `volume.conf` — volume path mappings
- `repos.conf` — GitHub repo declarations for key management
- `backup.conf` — backup schedule configuration

**FR-2.4: Concept Guides**
Longer-form explanations of key concepts:
- Project structure (engine vs. project directory)
- Environment model (`--env prod` reads `.prod.env`)
- Service profiles (`--services full|messaging|ui`)
- Registry support (GHCR, Docker Hub, ECR, none)
- Dry-run mode
- How health checks work (dynamic discovery via `services.conf`)
- Backup lifecycle (create → verify → schedule → retention → alerts)
- Drift detection and auto-fix
- Key management model (SSH, API, env, DB, GitHub)
- VPS audit and migration workflow

**FR-2.5: Recipes / Cookbook**
Task-oriented guides:
- "Deploy your first app to a $5 VPS"
- "Set up automated backups with retention"
- "Rotate all secrets after a team member leaves"
- "Migrate an existing Docker setup to strut"
- "Add SSL to your domain"
- "Sync production data to local dev"
- "Set up monitoring with Prometheus and Grafana"
- "Multi-stack deployment on a single VPS"

**FR-2.6: Search**
Client-side full-text search across all documentation pages.

### FR-3: Site-Wide

**FR-3.1:** Responsive design — works well on desktop and mobile (devs do read docs on phones).

**FR-3.2:** Dark mode by default with light mode toggle (matches terminal-centric audience).

**FR-3.3:** Syntax-highlighted code blocks with copy-to-clipboard buttons.

**FR-3.4:** Persistent left sidebar navigation for docs section with collapsible groups.

**FR-3.5:** "Edit this page on GitHub" link on every docs page.

**FR-3.6:** Version display pulled from the repo's `VERSION` file or GitHub release tag.

**FR-3.7:** SEO basics — proper meta tags, Open Graph tags, sitemap, canonical URLs.

---

## Non-Functional Requirements

### NFR-1: Performance
- Lighthouse performance score ≥ 90
- Static site generation — no server-side rendering needed at runtime
- Total landing page weight < 500KB (excluding fonts)

### NFR-2: Maintainability
- Documentation authored in Markdown files within the repo (docs-as-code)
- Minimal build tooling — ideally a single `npm run build` or equivalent
- CI/CD: auto-deploy on push to `main`

### NFR-3: Hosting
- Static hosting (GitHub Pages, Vercel, Netlify, or Cloudflare Pages)
- Custom domain support (e.g., `strut.dev` or `strutcli.dev`)
- HTTPS by default

### NFR-4: Accessibility
- Semantic HTML structure
- Keyboard navigable
- Sufficient color contrast in both themes
- Screen reader friendly navigation

---

## Tech Stack Recommendation

| Layer | Recommendation | Rationale |
|-------|---------------|-----------|
| Framework | Astro + Starlight | Purpose-built for docs sites, Markdown-first, fast static output, built-in search, dark mode, sidebar nav |
| Styling | Starlight defaults + minimal custom CSS | Avoid over-engineering the design |
| Code blocks | Expressive Code (bundled with Starlight) | Syntax highlighting, copy button, terminal frames |
| Search | Pagefind (bundled with Starlight) | Client-side, zero-config, fast |
| Hosting | GitHub Pages or Vercel | Free, auto-deploy from repo |
| CI | GitHub Actions | Build + deploy on push to main |

**Alternative considered:** Docusaurus, VitePress, Nextra. Starlight is recommended because it's the lightest, fastest, and most Markdown-native option with the least configuration overhead — which matches strut's philosophy.

---

## Sitemap (v1)

```
/                           → Landing / marketing page
/docs/                      → Getting started guide
/docs/installation/         → Installation details
/docs/quickstart/           → First deploy walkthrough
/docs/project-structure/    → Engine vs. project layout
/docs/configuration/        → strut.conf, services.conf, env files
/docs/commands/             → CLI reference index
/docs/commands/deploy/      → deploy command reference
/docs/commands/release/     → release command reference
/docs/commands/...          → (one page per command)
/docs/concepts/             → Concept guides index
/docs/concepts/environments/→ Environment model
/docs/concepts/profiles/    → Service profiles
/docs/concepts/health/      → Health check system
/docs/concepts/...          → (one page per concept)
/docs/recipes/              → Cookbook index
/docs/recipes/first-deploy/ → First deploy recipe
/docs/recipes/...           → (one page per recipe)
```

---

## Open Questions

1. **Domain:** What domain will the site live on? (`strut.dev`, `strutcli.dev`, `getstrut.dev`, or subdomain of existing?)
2. **Logo/branding:** Does strut have a logo or visual identity beyond the terminal output? Should we design one for the site?
3. **Analytics:** Do we want basic analytics (Plausible, Fathom) or none?
4. **Versioned docs:** Do we need to support multiple versions of docs (v0.x, v1.x) or just track `main`?
5. **Monorepo or separate repo:** Should the docs site live in this repo (e.g., `docs/` folder) or in a separate `strut-docs` repo?
6. **CLI reference generation:** Should we auto-generate command reference from the `usage()` output or maintain it manually in Markdown?
