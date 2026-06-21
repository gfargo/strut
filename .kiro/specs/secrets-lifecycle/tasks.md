# Tasks: Secrets Lifecycle Management

## Phase 1: Foundation & Bug Fixes

### Task 1: Fix env resolution in `cmd_diff.sh` (#145)
- [ ] Update `cmd_diff.sh` to use `_secrets_resolve_local_env` instead of raw `CMD_ENV_FILE`
- [ ] Implement layered sourcing: project-root first (for VPS connectivity), stack-level overlay
- [ ] Use `_secrets_resolve_remote_path` for the remote env filename
- [ ] Add regression test: stack with own `.prod.env` + project-root `.prod.env` → diff shows only stack's real pending changes
- [ ] Verify existing diff tests still pass

### Task 2: Merge PR #146 — `secrets hydrate` + provider system (#144)
- [ ] Pull branch locally, run `bats tests/test_secrets_providers.bats` + full suite
- [ ] Review `lib/secrets_providers.sh` for edge cases (empty values, special characters in resolved secrets)
- [ ] Review `_secrets_hydrate` in `lib/cmd_secrets.sh` for compatibility with existing subcommands
- [ ] Verify the `strut` entrypoint sources `secrets_providers.sh` before `cmd_secrets.sh`
- [ ] Verify shellcheck passes on new files
- [ ] Add one-liner to help text: "Only hydrate templates you trust — exec:// runs commands with your privileges"
- [ ] Consider adding `--template <path>` flag for non-standard template locations (enhancement, can defer)
- [ ] Merge and tag

---

## Phase 2: Key Generation & CI

### Task 3: Implement `ssh:keygen` (#142)
- [ ] Create `lib/cmd_ssh_keygen.sh` with the keygen flow
- [ ] Implement key naming: `~/.ssh/strut_<host>_<label>` (host resolved from stack topology)
- [ ] Route as `strut <stack> ssh:keygen --name <label>` — resolve host from `strut.conf [hosts]`
- [ ] Implement `--no-authorize` flag to skip remote authorization
- [ ] Implement `--output clipboard|stdout|<file>` modes
- [ ] Implement `--force` for overwriting existing keys
- [ ] Detect macOS vs Linux for clipboard support (`pbcopy` vs `xclip`/`xsel`)
- [ ] Key comment format: `strut-deploy/<host>/<label>@<date>`
- [ ] Register the command in the `strut` entrypoint dispatch
- [ ] Write bats tests: generation, no-overwrite guard, authorization mock, key comment format
- [ ] Update `keys` help text to cross-reference `ssh:keygen`

### Task 4: Implement `ci:init` (#143)
- [ ] Create `lib/cmd_ci_init.sh` with the bootstrapping flow
- [ ] Implement provider auto-detection (`.github/` → github, `.gitlab-ci.yml` → gitlab)
- [ ] Implement secret discovery from: strut.conf topology, env file, deploy key
- [ ] Implement `manual` output mode (checklist + paste-ready commands)
- [ ] Implement `github` output mode (via `gh secret set` when authenticated)
- [ ] Implement `--dry-run` and `--repo` overrides
- [ ] Consider a `ci_secrets` manifest file convention for explicit declaration
- [ ] Register the command in the dispatch
- [ ] Write bats tests: discovery logic, output formatting, gh-absent fallback to manual
- [ ] Document in steering and wiki

---

## Phase 3: Status & Integration

### Task 5: Add `secrets status` subcommand
- [ ] Implement `_secrets_status` in `cmd_secrets.sh`
- [ ] Show: local env location + var count, remote env status, template info, sync state
- [ ] Show: which providers were used (if template has references)
- [ ] Show: required_vars coverage
- [ ] Show: last push/pull timestamps (from file mtime)
- [ ] Register in the `secrets` dispatch case statement
- [ ] Write bats tests for each info section

### Task 6: Unified help & cross-references
- [ ] Update `_usage_secrets` to include `hydrate` and `status` with workflow guidance
- [ ] Add a "Typical Workflow" section to secrets help output
- [ ] Update `_usage_init_secrets` to mention `secrets hydrate` for external managers
- [ ] Update `_usage_keys` to mention `secrets push` for syncing after rotation
- [ ] Update steering docs (`.kiro/steering/stack-management.md`) with full secrets workflow

---

## Phase 4: Hardening & Extensions

### Task 7: Enhanced validation integration
- [ ] Ensure `secrets push` calls `_secrets_validate_required_vars` before upload (already does — verify)
- [ ] Add placeholder detection to `secrets validate` (reuse patterns from posture)
- [ ] Add `--skip-validation` flag to `secrets push` for operators who know what they're doing
- [ ] Post-hydrate: warn if any `required_vars` entries were not resolved

### Task 8: Provider documentation & extensibility guide
- [ ] Document the provider contract in a wiki page or steering file
- [ ] Include a worked example: "Adding a 1Password provider"
- [ ] Document `exec://` as the universal escape hatch with real examples (AWS SM, GCP SM, `op read`)
- [ ] Document security considerations for `exec://` (runs with caller's privileges)

### Task 9: New convenience commands
- [ ] `secrets rotate --env prod [--restart]` — hydrate --force (or init-secrets --force) + validate + push + optional restart
- [ ] `secrets template --env prod` — reverse-engineer a template from an existing .env (replace secret-looking values with placeholders + hints)
- [ ] `secrets export --format docker-secret|k8s-secret|env-json` — reformat .env to other secret storage formats
- [ ] `strut --all secrets push --env prod` — verify this works with topology-resolved hosts (likely already does via --all iteration)
- [ ] Write tests for each new subcommand
- [ ] Update help text and steering docs

### Task 10: Registry credential rotation (#148)
- [ ] Add `rotate-registry` subcommand to `lib/keys.sh` dispatch
- [ ] Implement token acceptance via stdin (never echo to logs/stdout)
- [ ] Iterate hosts from `strut.conf [hosts]` topology (respect `--hosts` filter)
- [ ] SSH to each host and `docker login --password-stdin`
- [ ] Post-login verification: test pull or auth check, report pass/fail per host
- [ ] Implement `registry-status` subcommand: per-host login state + registry
- [ ] Document the PAT creation limitation (link to GitHub token page)
- [ ] Document GitHub App installation tokens as the Phase 2 long-term approach
- [ ] Write bats tests: token delivery via stdin, multi-host iteration mock, status reporting

### Task 11: Future explorations (track as issues, implement later)
- [ ] `secrets lock/unlock` — encrypt .env at rest with age/sops (#147)
- [ ] Provider caching — skip unchanged secrets during re-hydration
- [ ] `secrets audit` — surface which secrets haven't been rotated in N days
- [ ] `--template <path>` override for hydrate (non-standard layouts)
- [ ] GitHub App token minting for registry auth (Phase 2 of #148)

---

## Dependency Graph

```
Task 1 (fix #145) ─────────────────────────────┐
                                                 │
Task 2 (merge #146 hydrate) ────────────────────┼──→ Task 5 (status)
                                                 │         │
Task 3 (ssh:keygen #142) ───→ Task 4 (ci:init)  │         ↓
                                                 └──→ Task 6 (help/docs)
                                                           │
Task 10 (rotate-registry #148) ─── independent ──┐        ↓
                                                  │  Task 7 (validation hardening)
                                                  │        │
                                                  │        ↓
                                                  │  Task 8 (provider docs)
                                                  │        │
                                                  │        ↓
                                                  └→ Task 9 (rotate, template, export, push-all)
                                                           │
                                                           ↓
                                                  Task 11 (future: lock, caching, audit, GH App)
```

Tasks 1-2 are independent and can be done in parallel.
Task 3 must precede Task 4 (ci:init needs deploy keys).
Tasks 5-6 depend on Phase 1-2 being complete.
Task 9 depends on the core pipeline being stable (Phases 1-3).
Task 10 (registry rotation) is independent — it extends `keys`, not `secrets`, and can be built anytime.
Task 11 items are tracked as separate GitHub issues for future prioritization.
