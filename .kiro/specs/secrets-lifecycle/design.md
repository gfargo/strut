# Design: Secrets Lifecycle Management

## Overview

This design unifies strut's secrets handling into a coherent pipeline with clear boundaries between layers. The architecture follows strut's existing patterns: shell functions in `lib/`, provider-based extensibility, stack-first resolution, and config-driven behavior.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        SECRETS LIFECYCLE PIPELINE                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌────────────┐  │
│  │   SOURCE     │──→│  LOCAL .env  │──→│   VALIDATE   │──→│  DISTRIBUTE│  │
│  │              │   │              │   │              │   │            │  │
│  │ init-secrets │   │ stack-level  │   │ required_vars│   │ push (VPS) │  │
│  │ hydrate      │   │   OR         │   │ placeholder  │   │ ci:init    │  │
│  │ ssh:keygen   │   │ project-level│   │ scanning     │   │            │  │
│  │ manual       │   │              │   │ format check │   │            │  │
│  └──────────────┘   └──────────────┘   └──────────────┘   └────────────┘  │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                     ONGOING MAINTENANCE                               │  │
│  │  diff (local vs remote) │ rotate (keys env:*) │ status │ posture     │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. Env File Resolution (fixes #145)

### Problem

`cmd_diff.sh` uses `CMD_ENV_FILE` (project-root) instead of the stack-first resolution that `secrets push` uses. This causes phantom diffs for stacks with their own env files.

### Solution: Single Resolution Function

`_secrets_resolve_local_env()` already exists in `cmd_secrets.sh` with the correct logic. The fix is to make `cmd_diff.sh` and any other env-consuming command use it.

```bash
# In cmd_diff.sh — replace:
#   local env_file="$CMD_ENV_FILE"
# With:
local env_file
env_file=$(_secrets_resolve_local_env "$stack_dir" "${env_name:-prod}")
if [ $? -ne 0 ] || [ ! -f "$env_file" ]; then
  env_file="$CMD_ENV_FILE"  # fallback for backward compat
fi
```

**Layered sourcing for VPS connection info:**
```bash
# Project-root first (has VPS_HOST, VPS_USER — infra-wide)
[ -f "$CMD_ENV_FILE" ] && { set -a; source "$CMD_ENV_FILE"; set +a; }
# Stack-level overlay (has stack-specific secrets, may override VPS vars)
[ "$env_file" != "$CMD_ENV_FILE" ] && [ -f "$env_file" ] && { set -a; source "$env_file"; set +a; }
```

This is exactly what the recent `cmd_diff.sh` edit implements. The same pattern should be adopted wherever VPS connectivity + stack secrets are both needed.

---

## 2. Provider Architecture (from PR #146)

### Provider Contract

```bash
# lib/secrets_providers.sh

# Registry — only these schemes are treated as references
SECRETS_PROVIDERS="${SECRETS_PROVIDERS:-vault exec file}"

# Required: resolve a reference target to a value on stdout
secrets_provider__<scheme>() {
  local target="$1"
  # ... resolve and print value ...
  # return non-zero on failure
}

# Optional: pre-flight check (CLI present, auth valid)
secrets_provider__<scheme>_check() {
  # return non-zero if provider can't run
}
```

### Built-in Providers

| Scheme | Resolution | Pre-flight |
|--------|-----------|------------|
| `vault://` | `bw get password <item>` (falls back to notes) | `bw` CLI present + `BW_SESSION` or `BW_CLIENTID` set |
| `exec://` | `bash -c "<command>"` | None (always available) |
| `file://` | `cat <path>` | File exists and is readable |

### Future Providers (not in initial scope, but the architecture supports them)

| Scheme | Resolution | Notes |
|--------|-----------|-------|
| `op://` | 1Password CLI (`op read`) | Popular in dev teams |
| `doppler://` | Doppler CLI (`doppler secrets get`) | SaaS secret manager |
| `aws-sm://` | AWS Secrets Manager (wrappable via `exec://` today) | Could add native caching |
| `age://` | Age-encrypted file decryption | For git-committed encrypted secrets |

### Scheme Detection Logic

The critical insight: only registered schemes are references. `postgres://user:pass@host` is NOT a reference because `postgres` is not in `SECRETS_PROVIDERS`. This is what makes the system backward-compatible.

```bash
secrets_reference_scheme() {
  local value="$1"
  if [[ "$value" =~ ^([a-z][a-z0-9+.-]*):// ]]; then
    local scheme="${BASH_REMATCH[1]}"
    case " $SECRETS_PROVIDERS " in
      *" $scheme "*) echo "$scheme"; return 0 ;;
    esac
  fi
  return 1
}
```

---

## 3. Hydrate Flow

```
┌─────────────────────────────────────────────────┐
│          strut <stack> secrets hydrate           │
├─────────────────────────────────────────────────┤
│                                                 │
│  1. Locate template:                            │
│     stacks/<s>/.<env>.env.template              │
│     → <root>/.<env>.env.template                │
│     → stacks/<s>/.env.template                  │
│     → <root>/.env.template                      │
│                                                 │
│  2. Scan: identify referenced schemes           │
│                                                 │
│  3. [dry-run exits here with preview]           │
│                                                 │
│  4. Pre-flight all referenced providers         │
│                                                 │
│  5. Resolve line-by-line:                       │
│     - reference → provider → value              │
│     - literal → pass through                    │
│     - multi-line value → FAIL                   │
│                                                 │
│  6. Atomic write (tmp in dest dir → rename)     │
│     chmod 600                                   │
│                                                 │
└─────────────────────────────────────────────────┘
```

**Template search order** (env-specific first, then generic):
1. `stacks/<stack>/.<env>.env.template`
2. `<project-root>/.<env>.env.template`
3. `stacks/<stack>/.env.template`
4. `<project-root>/.env.template`

**Output location**: Same directory as the template found, named `.<env>.env`. This ensures it lands where `_secrets_resolve_local_env` (and therefore `secrets push`) will find it.

---

## 4. Deploy Key Generation (`ssh:keygen`)

### Command Surface

```bash
strut <host> ssh:keygen --name <label> [--type ed25519|rsa] \
  [--output clipboard|stdout|<file>] [--no-authorize] [--force]
```

Note: This operates on a *host* (from `strut.conf [hosts]`), not a stack. Deploy keys are per-host, shared across stacks on that host.

### Implementation Location

New file: `lib/cmd_ssh_keygen.sh`

This is separate from `lib/keys/ssh.sh` (which manages per-stack SSH keys for users). Deploy keys are infrastructure-level, not stack-level.

### Key Naming Convention

```
~/.ssh/strut_<host>_<label>      # private key
~/.ssh/strut_<host>_<label>.pub  # public key
```

Example: `~/.ssh/strut_harbor_github-actions-ci`

### Authorization Flow

```bash
# 1. Generate
ssh-keygen -t ed25519 -f "$key_path" -N "" -C "strut-deploy/$host/$label@$(date +%Y-%m-%d)"

# 2. Authorize (unless --no-authorize)
cat "$key_path.pub" | ssh <host> "cat >> ~/.ssh/authorized_keys"

# 3. Output
case "$output_mode" in
  clipboard) cat "$key_path" | pbcopy ;; # macOS; xclip on Linux
  stdout)    cat "$key_path" ;;
  *)         echo "Private key: $key_path" ;;
esac
```

---

## 5. CI/CD Secret Bootstrapping (`ci:init`)

### Command Surface

```bash
strut <stack> ci:init [--provider github|gitlab|manual] \
  [--repo <owner/repo>] [--dry-run]
```

### Secret Discovery Algorithm

```
1. Read strut.conf [hosts] → find the host for this stack
2. Look for deploy key: ~/.ssh/strut_<host>_*ci* (or prompt to generate)
3. Read connection info from env file: VPS_HOST, VPS_USER
4. Read stack-specific secrets from env file that CI would need
5. Categorize each secret:
   - AUTO: derivable from strut.conf/topology (host, user, deploy dir)
   - KEY:  deploy key file contents
   - ENV:  value from .env that CI needs (API URLs, project refs)
   - MANUAL: needs human input (OAuth tokens — provide setup URLs)
```

### Output Modes

**manual (default):**
```
CI secrets needed for stack "my-app" → harbor:

  DEPLOY_SSH_KEY     ✓ From: ~/.ssh/strut_harbor_ci
  DEPLOY_HOST        = harbor.tail1234.ts.net (from strut.conf)
  DEPLOY_USER        = gfargo (from strut.conf)
  TS_OAUTH_CLIENT_ID ? Set up at: https://login.tailscale.com/admin/settings/oauth
  TS_OAUTH_SECRET    ? (same page as above)
  API_URL            = https://api.example.com (from .prod.env)

Commands to set GitHub secrets:
  gh secret set DEPLOY_SSH_KEY < ~/.ssh/strut_harbor_ci
  gh secret set DEPLOY_HOST --body "harbor.tail1234.ts.net"
  ...
```

**github (with `gh` CLI):**
```
Pushing 4 secrets to gfargo/my-app...
  ✓ DEPLOY_SSH_KEY
  ✓ DEPLOY_HOST
  ✓ DEPLOY_USER
  ✓ API_URL
  ⚠ 2 secrets need manual entry — run without --yes to see instructions
```

---

## 6. Secrets Status & Metadata

### `secrets status` Subcommand

A new subcommand showing the state of the secrets pipeline for a stack:

```bash
strut my-app secrets status --env prod

Secrets Status: my-app (prod)
─────────────────────────────────────────────
Local env:   stacks/my-app/.prod.env (12 vars, 0600, modified 2h ago)
Remote env:  /home/gfargo/strut/.prod.env (12 vars, synced)
Template:    stacks/my-app/.prod.env.template (8 refs, 4 literals)
Diff:        ✓ In sync

Providers used: vault (3 keys), exec (2 keys), file (1 key)
Last hydrate:   2026-06-20 14:30 UTC
Last push:      2026-06-20 14:35 UTC

Required vars:  12/12 present ✓
Posture:        No issues
```

This is informational — it reads from file timestamps and a lightweight metadata sidecar (`.secrets-meta.json`) that hydrate/push can maintain.

---

## 7. Integration Points

### With `diff` Command

The top-level `strut <stack> diff` already shows env var differences alongside compose/image changes. After fixing #145, this uses `_secrets_resolve_local_env` and the layered sourcing pattern.

### With `deploy` Command

`deploy` already validates `required_vars` before deploying. No changes needed — the existing `PRE_DEPLOY_VALIDATE` hook catches missing vars.

### With `keys env:rotate`

`keys env:rotate` generates new random values for secrets in the env file. After rotation:
1. The local env file has new values
2. `secrets diff` shows the local/remote divergence
3. `secrets push` syncs to VPS
4. `deploy` picks up the new values on next container restart

No new integration needed — the pipeline already flows correctly.

### With `posture`

`posture --category secrets` scans for weak/placeholder values, git-tracked env files, etc. This remains the comprehensive audit. `secrets validate` is the targeted pre-push gate.

---

## 8. Command Taxonomy (Final State)

```
# ── Source & Populate ─────────────────────────────────────────────────────────
strut <stack> init-secrets --env prod         # Generate random secrets from template
strut <stack> secrets hydrate --env prod      # Resolve references from external managers
strut <stack> secrets template --env prod     # Reverse-engineer a template from existing .env

# ── Validate & Inspect ────────────────────────────────────────────────────────
strut <stack> secrets validate --env prod     # Check required_vars + scan for issues
strut <stack> secrets diff --env prod         # Compare local vs remote (keys only)
strut <stack> secrets status --env prod       # Show pipeline state

# ── Distribute ────────────────────────────────────────────────────────────────
strut <stack> secrets push --env prod         # Upload .env to VPS
strut <stack> secrets pull --env prod         # Download .env from VPS
strut <stack> secrets export --format <fmt>   # Export to docker-secret / k8s-secret YAML
strut --all secrets push --env prod           # Push across all stacks/hosts

# ── Rotate ────────────────────────────────────────────────────────────────────
strut <stack> secrets rotate --env prod       # Convenience: hydrate --force + push + restart
strut <stack> keys env:rotate                 # Rotate generated secrets (low-level)
strut <stack> keys status                     # Key health dashboard

# ── Infrastructure ────────────────────────────────────────────────────────────
strut <stack> ssh:keygen --name ci            # Generate deploy keypair + authorize on host
strut <stack> ci:init --provider github       # Bootstrap CI secrets
```

---

## 9. New Workflows (post-Phase 2)

### 9a. `secrets rotate` — Convenience Wrapper

Combines re-hydration (or re-generation) with push and optional container restart:

```bash
strut <stack> secrets rotate --env prod [--restart]
```

Flow:
1. If template has provider references → `secrets hydrate --force`
2. If template has generated secrets → `init-secrets --force` (or `keys env:rotate`)
3. `secrets validate`
4. `secrets push --force`
5. If `--restart` → SSH to VPS and `docker compose restart` (or `deploy`)

This is the "I rotated a secret in my vault, propagate it everywhere" button.

### 9b. `secrets template` — Reverse-Engineer Template from .env

For brownfield stacks that have a running `.prod.env` but no template:

```bash
strut <stack> secrets template --env prod [--dry-run]
```

Flow:
1. Read the existing `.env` file
2. For each KEY=VALUE:
   - If value matches known secret patterns (long hex, base64, random-looking) → replace with `change-me` + generation hint comment
   - If value looks like a URL, hostname, or structured data → keep as literal
   - If value matches a key name heuristic (PASSWORD, SECRET, TOKEN) → mark as placeholder
3. Write `stacks/<stack>/.env.template` (or `.<env>.env.template`)
4. Print summary: "N secrets replaced with placeholders, M literals preserved"

Makes older stacks hydrate-ready without manual template authoring.

### 9c. `secrets export --format`

Export the local env file to other secret formats:

```bash
strut <stack> secrets export --format docker-secret --env prod > secrets.yml
strut <stack> secrets export --format k8s-secret --env prod > secret.yaml
strut <stack> secrets export --format dotenv-vault --env prod  # .env.vault format
```

Formats:
- `docker-secret` → Docker Swarm `docker secret create` commands or compose secrets YAML
- `k8s-secret` → Kubernetes Secret manifest (base64-encoded data)
- `env-json` → JSON object `{"KEY": "value", ...}` for tooling that consumes JSON

Low effort — it's just reformatting KEY=VALUE pairs. Useful for migration paths.

### 9d. `secrets push-all` (via `--all`)

Strut already supports `strut --all <command>` for multi-stack operations. With the `[hosts]` topology, `secrets push --env prod` under `--all` iterates all stacks and pushes each to its correct host:

```bash
strut --all secrets push --env prod
# Pushes homepage → harbor, agent-platform → harbor, monitoring → pi-ops, etc.
```

No new code beyond ensuring `secrets push` works correctly with topology-resolved hosts (which it already does via env file sourcing).

### 9e. `ssh:keygen` Scoping Decision

**Decision: Per-stack, not per-host.** Each stack gets its own deploy key via `strut <stack> ssh:keygen --name ci`. This encourages proper key segmentation — revoking access to one stack doesn't affect others. The host is resolved from topology automatically.

If an operator wants a shared key across stacks, they can generate one manually and reference it in multiple stacks' CI configs. Strut's tooling encourages the secure default (one key per deployment scope).

### 9f. Registry Credential Rotation (`keys rotate-registry`)

Registry pull tokens (ghcr.io PATs for private images) are a cross-host concern. Unlike env-file secrets which are per-stack, a registry credential is per-host — every stack on that host shares the same `docker login` session.

**Command surface:**
```bash
strut keys rotate-registry [--registry ghcr.io] [--hosts all|harbor,compass] [--revoke-old]
strut keys registry-status
```

**Flow:**
```
1. Prompt for / accept new token (stdin, never echoed)
2. For each host in topology:
   a. SSH to host
   b. echo "$token" | docker login <registry> --username <user> --password-stdin
   c. Verify: docker pull <test-image> OR registry auth check
   d. Report pass/fail
3. Summary: "3/3 hosts authenticated to ghcr.io ✓"
```

**Design decisions:**

- **Guided rotation (Phase 1)**: Strut opens/links the PAT creation page, accepts the token, distributes. This is the immediate, low-effort win since GitHub doesn't support programmatic PAT creation.
- **GitHub App tokens (Phase 2)**: A strut GitHub App mints short-lived installation tokens (~1h) with `packages:read`. Hosts refresh via a helper cron/systemd timer. No static secret on any host. This is the proper long-term architecture.
- **Lives under `keys`**, not `secrets`: Registry auth is a credential/key concern (managed per-host), not an env-file concern (managed per-stack). The `keys` subsystem already has `github:*` subcommands.

**Interaction with the secrets pipeline:**
- If a stack's `.env.template` has `REGISTRY_TOKEN=vault://...` for CI pipelines, `hydrate` handles that
- `rotate-registry` is for the *host-level* Docker daemon auth, separate from what's in `.env` files
- `registry-status` fits alongside `keys status` as infrastructure health reporting

---

## 10. Reviewer Feedback Integration (PR #146)

Incorporating the code review findings into our spec:

| Feedback Item | Action |
|---------------|--------|
| `exec://` security: "only hydrate templates you trust" | Add one-liner to help text in the `secrets` usage output |
| No `--template <path>` override | Add as enhancement to Task 2 — allow `secrets hydrate --template <path>` for non-standard layouts |
| CI status pending (new account) | Pull branch locally, run `bats tests/test_secrets_providers.bats` + full suite before merge |
| `trap RETURN` is bash-only | Fine — strut requires bash. No action needed. |

---

## 11. File Layout (New/Modified)

```
lib/
  secrets_providers.sh          # NEW — provider registry + vault/exec/file (from PR #146)
  cmd_secrets.sh                # MODIFIED — add hydrate, status, template, rotate, export subcommands
  cmd_ssh_keygen.sh             # NEW — deploy key generation
  cmd_ci_init.sh                # NEW — CI secret bootstrapping
  cmd_diff.sh                   # MODIFIED — use _secrets_resolve_local_env
```

---

## 10. Open Design Questions

### Q1: Should `hydrate` live under `secrets` or be a separate top-level command?

**Decision: Under `secrets`.** It's part of the same pipeline (template → local .env → remote). The PR puts it at `secrets hydrate`, which keeps the command surface tight. `init-secrets` remains separate because it predates the `secrets` namespace and has different semantics (generate vs fetch).

### Q2: Should `ssh:keygen` operate on a host or a stack?

**Decision: Per-stack.** Routes through `strut <stack> ssh:keygen --name ci`. The host is resolved from topology. This encourages proper key segmentation — one deploy key per stack/deployment scope. Revoking one stack's CI access doesn't affect others. Operators who want a shared key can generate manually and reference across stacks.

### Q3: Should we merge the `keys` subsystem into `secrets` long-term?

**Decision: No, not now.** `keys` is a large, mature subsystem (SSH keys, API keys, DB credentials, GitHub secrets, audit logging). Merging would be a major UX change. Keep them separate but cross-reference in help text. Long-term, if the overlap becomes confusing, consider aliasing.

### Q4: Should `secrets status` track metadata in a sidecar file?

**Decision: Start simple.** Use file timestamps and remote queries for status. A `.secrets-meta.json` sidecar adds complexity. If operators want richer tracking (who last pushed, from where), add it later as opt-in.

### Q5: How should `ci:init` discover which env vars CI needs?

**Decision: Convention + config.** Start with a `ci_secrets` file in the stack dir (like `required_vars` but for CI). If absent, infer from standard patterns (DEPLOY_HOST, DEPLOY_USER, DEPLOY_SSH_KEY are always needed). The issue #143 proposal of reading from the workflow file itself is fragile — better to have an explicit manifest.
