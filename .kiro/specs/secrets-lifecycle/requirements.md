# Requirements: Secrets Lifecycle Management

## Introduction

Strut manages Docker stack deployments on VPS hosts, and secrets (env vars, SSH keys, API tokens) are the connective tissue between local development and remote infrastructure. Today strut has several secrets-adjacent capabilities (`init-secrets`, `secrets push/pull/diff/validate`, `keys *`, `posture`), but they were built incrementally and have gaps in the end-to-end workflow.

This spec unifies the secrets lifecycle into a coherent system: from *sourcing* secrets (generating, fetching from managers, creating deploy keys) through *local management* (validation, diffing, hydration) to *distribution* (pushing to VPS, bootstrapping CI) and *ongoing maintenance* (rotation, audit, drift detection).

## Related Issues

| Issue | Title | Status |
|-------|-------|--------|
| #119 | `init-secrets` — generate .env from template | Done |
| #130 | `secrets push/pull/diff/validate` | Done |
| #144 | `secrets hydrate` — populate from secret manager | PR #146 open |
| #145 | `diff` shows phantom changes for stack-level envs | Open (bug) |
| #142 | `ssh:keygen` — generate deploy keypairs | Open |
| #143 | `ci:init` — bootstrap CI/CD secrets | Open |
| #25 | Secret scanning in validate/pre-deploy | Done |
| #41 | Security posture audit | Done |
| #147 | `secrets lock/unlock` — encrypt .env at rest | Open (future) |
| #148 | `keys rotate-registry` — rotate/redistribute registry pull tokens | Open |

## Glossary

- **Env_File**: A `.env`-formatted file (KEY=VALUE, one per line) consumed by Docker Compose's `env_file` directive or sourced by strut for VPS connection info
- **Template**: A `.env.template` file containing placeholder values and generation hints; used by `init-secrets` and `hydrate`
- **Stack_Env**: An env file at `stacks/<stack>/.<env>.env` — takes precedence over project-level
- **Project_Env**: An env file at `<project-root>/.<env>.env` — fallback when no stack-level exists
- **Secret_Reference**: A `<scheme>://<target>` value in a template that `hydrate` resolves from an external source
- **Provider**: A pluggable module that resolves secret references (vault, exec, file, and future additions)
- **Env_Resolution**: The algorithm for finding the correct env file: stack-level first, then project-level fallback
- **Remote_Env_Path**: The path on the VPS where the env file is deployed (e.g., `/home/ubuntu/strut/.prod.env`)
- **Deploy_Key**: A purpose-specific SSH keypair used only for CI/CD deploys, not personal access
- **CI_Secret**: A secret value stored in a CI provider (GitHub Actions secrets, GitLab CI variables) for automated deploys

---

## Requirements

### Requirement 1: Consistent Env File Resolution

**User Story:** As a stack operator, I want all strut commands that read env files to use the same resolution logic (stack-level first, project-level fallback), so that a stack with its own `.prod.env` never gets confused with the project-root env.

#### Acceptance Criteria

1. THE `_secrets_resolve_local_env()` function SHALL be the single authority for finding local env files, used by `secrets push`, `secrets pull`, `secrets diff`, `secrets validate`, `secrets hydrate`, `diff`, and `deploy`
2. WHEN a stack has `stacks/<stack>/.<env>.env`, ALL env-reading commands SHALL prefer it over `<project-root>/.<env>.env`
3. THE `diff` command SHALL use `_secrets_resolve_local_env` for its local env source and `_secrets_resolve_remote_path` for its remote target — NOT the legacy `CMD_ENV_FILE` variable directly
4. WHEN sourcing VPS connection info (VPS_HOST, VPS_USER, etc.), commands SHALL source the project-root env first (for connectivity), then overlay the stack-level env (for stack-specific values)
5. THE remote env filename SHALL be derived consistently from `env_name` via `_secrets_resolve_remote_path` across `diff`, `deploy`, `secrets push`, and `secrets pull`

*Fixes #145*

---

### Requirement 2: Secret Hydration from External Managers

**User Story:** As a stack operator with secrets in Vaultwarden/Bitwarden, AWS Secrets Manager, or files, I want to build my `.env` from a template that references those external sources, so I never hand-paste secrets into plaintext files.

#### Acceptance Criteria

1. THE `secrets hydrate --env <name>` subcommand SHALL read a template file, resolve any `<scheme>://<target>` values through the provider system, and write the result as a `.env` file
2. THE following schemes SHALL be recognized as secret references: `vault`, `exec`, `file`
3. VALUES using unregistered schemes (e.g., `postgres://`, `https://`) SHALL pass through as literals without modification
4. THE `--dry-run` flag SHALL preview which keys map to which providers WITHOUT requiring provider credentials and WITHOUT writing any file
5. THE output SHALL be written atomically (temp file in destination dir, renamed into place) with mode 0600
6. IF any resolved value contains a newline, THE command SHALL fail with a clear error (`.env` format cannot represent multi-line values) and SHALL NOT write a partial file
7. BEFORE resolving any references, THE command SHALL pre-flight all referenced providers (check CLI presence, session validity) — failing fast with no partial output
8. THE `--force` flag SHALL allow overwriting an existing output file; without it, existing files SHALL NOT be overwritten
9. THE provider system SHALL be extensible: adding a new provider requires defining a `secrets_provider__<scheme>()` function and registering the scheme in `SECRETS_PROVIDERS`

*Addresses #144 / PR #146*

---

### Requirement 3: Deploy Keypair Generation

**User Story:** As a stack operator setting up CI/CD, I want strut to generate a dedicated SSH keypair and authorize it on the target host, so I have a properly scoped deploy key without manual ceremony.

#### Acceptance Criteria

1. THE `ssh:keygen --name <label>` command SHALL generate an ed25519 keypair at `~/.ssh/strut_<host>_<label>`
2. THE command SHALL NOT overwrite an existing keypair with the same name unless `--force` is passed
3. BY DEFAULT, the command SHALL SSH to the target host and append the public key to `~/.ssh/authorized_keys` (skippable with `--no-authorize`)
4. THE private key SHALL be outputtable via `--output clipboard|stdout|<file>` (default: file path is printed)
5. THE key comment SHALL follow the format `strut-deploy/<host>/<label>@<date>` for auditability
6. THE command SHALL print a summary: key path, fingerprint, which host was authorized
7. THE command SHALL use the same SSH connection method as other strut commands (respecting `strut.conf [hosts]` topology)

*Addresses #142*

---

### Requirement 4: CI/CD Secret Bootstrapping

**User Story:** As a stack operator, I want strut to determine which secrets my CI pipeline needs and either output the `gh secret set` commands or push them directly, so I don't manually piece together 6-8 secrets one at a time.

#### Acceptance Criteria

1. THE `ci:init --provider <name>` command SHALL detect required CI secrets from: the stack's env file, `strut.conf [hosts]` topology, and the deploy key generated by `ssh:keygen`
2. SUPPORTED providers SHALL be: `github` (via `gh` CLI), `gitlab` (via `glab` CLI), and `manual` (prints a checklist)
3. THE `--provider` flag SHALL default to auto-detection from `.github/` or `.gitlab-ci.yml` presence in the project
4. WHEN `--dry-run` is passed, THE command SHALL output what secrets would be set without executing anything
5. FOR the `github` provider, WHEN `gh` is authenticated, THE command SHALL offer to push secrets via `gh secret set` (interactive confirmation unless `--yes`)
6. THE command SHALL categorize secrets as: auto-resolvable (host, user, deploy key path → from strut.conf/keygen), env-sourced (API URLs → from .env), and manual-entry (OAuth tokens → prints instructions with URLs)
7. THE `--repo <owner/repo>` flag SHALL override auto-detection from `git remote`

*Addresses #143*

---

### Requirement 5: Secrets Rotation Awareness

**User Story:** As a stack operator, I want `secrets hydrate` and `keys env:rotate` to work together, so that rotating a secret in my vault is reflected locally by re-running hydrate, and rotating a generated secret updates the remote via push.

#### Acceptance Criteria

1. WHEN `secrets hydrate --force` is run, ALL provider references SHALL be re-resolved (fetching current values from the external source), overwriting the local env file
2. THE `keys env:rotate` command SHALL continue to rotate locally-generated secrets (passwords, tokens) and update the env file in place
3. AFTER rotation or re-hydration, THE operator SHALL be prompted (or documented) to run `secrets push` to sync the new values to the VPS
4. THE `secrets diff` command SHALL detect key/value differences between local and remote, enabling operators to verify that rotation was synced
5. A `secrets status` subcommand SHALL show per-key metadata: source (generated/hydrated/manual), last modified, whether local differs from remote

---

### Requirement 6: Unified Secrets Help & Discoverability

**User Story:** As a new strut user, I want a single `strut <stack> secrets` entry point that shows me the full secrets workflow, so I understand what's available without reading wiki pages.

#### Acceptance Criteria

1. THE `secrets` command with no subcommand SHALL display a help message listing ALL subcommands: `hydrate`, `push`, `pull`, `diff`, `validate`, `status`
2. THE help output SHALL include a "Workflow" section showing the typical order: `init-secrets` OR `hydrate` → `validate` → `push` → `diff` (verify)
3. THE `init-secrets` command help SHALL cross-reference `secrets hydrate` for the "fetch from manager" use case
4. THE `keys` command help SHALL cross-reference `secrets push` for syncing rotated values to VPS

---

### Requirement 7: Provider Ecosystem Extensibility

**User Story:** As a contributor, I want to add support for a new secret manager (1Password, Doppler, HashiCorp Vault) by implementing one function and registering it, without modifying the hydrate logic itself.

#### Acceptance Criteria

1. THE provider contract SHALL be: `secrets_provider__<scheme>()` takes a target string on `$1` and prints the resolved value to stdout (returning non-zero on failure)
2. AN optional `secrets_provider__<scheme>_check()` function SHALL pre-flight the provider (check CLI presence, auth state) — called once before any resolution begins
3. THE `SECRETS_PROVIDERS` variable SHALL be the registry of recognized schemes, overridable via environment for testing or project-specific extensions
4. DOCUMENTATION SHALL exist (in steering and/or wiki) describing the provider contract, with a worked example of adding a new provider
5. THE `exec://` provider SHALL remain the universal escape hatch — any CLI command can be wrapped as a reference without writing a native provider

---

### Requirement 8: Secret Scanning Integration

**User Story:** As a stack operator, I want secrets validation (scanning for weak/placeholder values) to run automatically before `secrets push` and during `strut validate`, catching problems before they reach the VPS.

#### Acceptance Criteria

1. THE `secrets validate` subcommand SHALL check: required_vars presence, placeholder detection (same patterns as posture), and known-weak-secret patterns (from #25)
2. THE `secrets push` command SHALL run validation before uploading — failing with a clear message if issues are found (skippable with `--skip-validation`)
3. THE `posture` command's secrets category SHALL remain the comprehensive audit; `secrets validate` is the pre-push gate focused on the current stack
4. POST-hydration, THE system SHALL warn if any keys in `required_vars` were not resolved (provider failure or missing reference)

---

### Requirement 9: Registry Credential Rotation & Distribution

**User Story:** As a multi-host operator with private container images (ghcr.io), I want strut to rotate the registry pull token and distribute it to all hosts in one command, so a leaked or expired token is a single action instead of manual per-node `docker login`.

#### Acceptance Criteria

1. THE `keys rotate-registry` command SHALL accept a new token (via stdin or interactive prompt) and execute `docker login --password-stdin` on each target host over SSH
2. THE `--hosts` flag SHALL allow targeting `all` (from `strut.conf [hosts]`) or specific hosts; default: all
3. THE `--registry` flag SHALL specify the registry (default: `ghcr.io`)
4. AFTER login, THE command SHALL verify each host with a test `docker pull` or registry token check, reporting pass/fail per host
5. THE token SHALL NEVER be echoed to stdout, logs, or command history — delivery exclusively via `--password-stdin` to `docker login`
6. A `keys registry-status` subcommand SHALL report login state per host: which registry, whether authenticated, token age if detectable
7. THE `--revoke-old` flag SHALL document the limitation that GitHub PATs cannot be programmatically revoked, and link to the manual revocation page
8. DOCUMENTATION SHALL note the GitHub App installation token approach as the recommended long-term solution for automated rotation (short-lived tokens, no static secrets)

*Addresses #148*

---

## Non-Functional Requirements

### Security

- Secret values SHALL NEVER be printed to stdout or logs during normal operation (dry-run shows key-to-provider mapping, not values)
- Env files created by strut SHALL always have mode 0600
- The `exec://` provider executes arbitrary commands with the caller's privileges — templates are user-authored, operator-consented; strut SHALL document this in help and steering
- Deploy keys SHALL use ed25519 by default (modern, short, fast)

### Backward Compatibility

- All existing `secrets push/pull/diff/validate` behavior SHALL remain unchanged
- The `init-secrets` command SHALL continue to work independently of the hydration system
- Projects without templates or providers SHALL experience no change in behavior
- The `keys` subsystem SHALL remain a separate command surface; this spec does not merge it into `secrets`

### Performance

- Provider resolution during `hydrate` SHALL be sequential (simplicity over parallelism for a one-time operation)
- `secrets diff` SHALL use a single SSH connection (via mux) for fetching the remote env

### Portability

- All commands SHALL work on macOS (BSD userland) and Linux
- The `vault://` provider requires `bw` CLI; its absence SHALL produce a clear error, not a cryptic failure
- The `file://` provider SHALL work with any readable file path
