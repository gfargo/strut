# strut Marketing & Documentation Website — Tasks

#[[file:requirements.md]]
#[[file:design.md]]

---

## Phase 1: Foundation (MVP)

- [ ] 1. Initialize Astro + Starlight project in `docs-site/` directory
  - Run `npm create astro@latest` with Starlight template
  - Configure `astro.config.mjs` with site metadata, sidebar structure, and dark mode default
  - Verify local dev server runs and builds cleanly

- [ ] 2. Create the marketing landing page (`src/pages/index.astro`)
  - Build Hero component with tagline, subtitle, and copyable install command
  - Build Features component with 6-8 capability cards
  - Build InstallBlock component with terminal-style code display and copy button
  - Style with dark-first design, monospace code font, muted blue/teal accent
  - Add responsive layout for mobile/tablet/desktop
  - Link "Read the Docs" CTA to `/docs/`

- [ ] 3. Write Getting Started documentation
  - `docs/index.mdx` — docs landing / overview
  - `docs/installation.md` — prerequisites, install methods, PATH setup
  - `docs/quickstart.md` — init → scaffold → configure → deploy walkthrough
  - `docs/project-structure.md` — engine vs. project directory, file explanations

- [ ] 4. Write Configuration reference docs
  - `docs/configuration/strut-conf.md` — all keys with defaults and descriptions
  - `docs/configuration/services-conf.md` — service declaration format, health paths, DB flags
  - `docs/configuration/env-files.md` — naming conventions, per-env files, required_vars, volume.conf, repos.conf, backup.conf

- [ ] 5. Set up GitHub Actions deploy pipeline
  - Create `.github/workflows/deploy-docs.yml`
  - Build on push to `main` when `docs-site/**` changes
  - Deploy to GitHub Pages (or Vercel/Netlify depending on decision)

- [ ] 6. Add nav bar and footer
  - Logo + site title in nav
  - "Docs" and "GitHub" links in nav
  - Dark/light mode toggle
  - Footer with GitHub link, version, license

## Phase 2: Full CLI Reference

- [ ] 7. Create command reference index page (`docs/commands/index.md`)
  - Grouped table of all commands with one-line descriptions and "runs where" column
  - Links to individual command pages

- [ ] 8. Write Deployment & Lifecycle command pages
  - `docs/commands/release.md`
  - `docs/commands/deploy.md`
  - `docs/commands/stop.md`
  - `docs/commands/update.md`
  - `docs/commands/upgrade.md`
  - Each follows the command reference template from design doc

- [ ] 9. Write Observability command pages
  - `docs/commands/health.md`
  - `docs/commands/logs.md`
  - `docs/commands/status.md`

- [ ] 10. Write Database command pages
  - `docs/commands/backup.md`
  - `docs/commands/restore.md`
  - `docs/commands/db-pull.md`
  - `docs/commands/db-push.md`
  - `docs/commands/db-schema.md`
  - `docs/commands/migrate.md`

- [ ] 11. Write Infrastructure command pages
  - `docs/commands/drift.md`
  - `docs/commands/keys.md`
  - `docs/commands/volumes.md`
  - `docs/commands/domain.md`
  - `docs/commands/monitoring.md`

- [ ] 12. Write Development command pages
  - `docs/commands/local.md` (covers all local subcommands)
  - `docs/commands/debug.md` (covers all debug subcommands)

- [ ] 13. Write Project Management command pages
  - `docs/commands/init.md`
  - `docs/commands/scaffold.md`
  - `docs/commands/list.md`
  - `docs/commands/audit.md`
  - `docs/commands/migrate-wizard.md`

- [ ] 14. Verify Pagefind search works across all docs pages

## Phase 3: Concepts & Recipes

- [ ] 15. Write Concept guide pages
  - `docs/concepts/environments.md` — env model, `--env` flag, `.prod.env` convention
  - `docs/concepts/profiles.md` — service profiles, `--services` flag
  - `docs/concepts/health-checks.md` — dynamic discovery, services.conf-driven checks
  - `docs/concepts/backup-lifecycle.md` — create → verify → schedule → retention → alerts
  - `docs/concepts/drift-detection.md` — detect, report, fix, auto-fix, monitoring
  - `docs/concepts/key-management.md` — SSH, API, env, DB, GitHub key workflows

- [ ] 16. Write Recipe / Cookbook pages
  - `docs/recipes/first-deploy.md` — end-to-end VPS deploy on a $5 server
  - `docs/recipes/automated-backups.md` — backup schedule + retention + alerts
  - `docs/recipes/secret-rotation.md` — rotate keys after team change
  - `docs/recipes/migrate-existing.md` — audit + generate from existing Docker setup
  - `docs/recipes/ssl-domain.md` — domain + Let's Encrypt SSL setup
  - `docs/recipes/local-dev-sync.md` — sync prod data to local, anonymize
  - `docs/recipes/monitoring.md` — Prometheus + Grafana setup

- [ ] 17. Add Comparison section to landing page
  - Build Comparison component with table: strut vs. Kubernetes vs. Kamal vs. manual scripts
  - Columns: complexity, learning curve, time to first deploy, multi-stack, backup/restore, drift detection

- [ ] 18. Add Personas section to landing page
  - Build Personas component with 3 cards: solo dev, small team, agency

## Phase 4: Polish

- [ ] 19. Add SEO and social meta tags
  - Open Graph image (`og-image.png`)
  - Meta descriptions on all pages
  - Canonical URLs
  - Sitemap generation via Astro

- [ ] 20. Add "Edit this page on GitHub" links to all docs pages
  - Configure Starlight's `editLink` option with the repo URL

- [ ] 21. Add version badge
  - Display current strut version on landing page and docs nav
  - Pull from `VERSION` file at build time or GitHub API

- [ ] 22. Lighthouse audit and performance pass
  - Target score ≥ 90 on all categories
  - Optimize images, fonts, and CSS
  - Verify total landing page weight < 500KB

- [ ] 23. Custom domain setup
  - Configure DNS for chosen domain
  - Set up HTTPS
  - Update all internal links and references
