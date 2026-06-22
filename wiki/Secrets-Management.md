# Secrets Management

How strut moves secrets from an external manager into your VPS `.env` files — and how to extend the provider system to support new sources.

## Overview

The `secrets hydrate` command reads a `.env.template` file, resolves any `<scheme>://<ref>` references through the pluggable provider system, and writes a `.env` file with mode `0600`. Literal values are copied unchanged, so the default behaviour requires no external tooling.

```
.env.template  →  secrets hydrate  →  .env  →  secrets push  →  VPS
                      ↑
              secrets_providers.sh
           (vault / exec / file / custom)
```

## Reference Syntax in Templates

A template value that looks like `<scheme>://<target>` is a reference; everything else is literal.

```dotenv
# References — resolved at hydrate time
DB_PASSWORD=vault://my-db-item
API_TOKEN=exec://aws secretsmanager get-secret-value --secret-id my/api-token --query SecretString --output text
SIGNING_KEY=file:///run/secrets/signing-key

# Literals — copied as-is (postgres:// is not a registered scheme)
DATABASE_URL=postgres://user:pass@localhost/db
APP_ENV=production
```

Only schemes listed in `SECRETS_PROVIDERS` are treated as references. A value like `postgres://...` or `https://...` passes through unchanged even though it looks like a URI.

## Built-in Providers

### `vault://` — Bitwarden / Vaultwarden

Resolves via the `bw` CLI. The target is the item name or ID. The password field is preferred; if empty, the notes field is used.

```dotenv
DB_PASSWORD=vault://my-db-item
JWT_SECRET=vault://jwt-signing-key
```

**Pre-flight requirements:**
- `bw` CLI installed and in `PATH`
- `BW_SESSION` exported (from `bw unlock --raw`), or `BW_CLIENTID` / `BW_CLIENTSECRET` set

```bash
export BW_SESSION="$(bw unlock --raw)"
strut myapp secrets hydrate --env prod
```

### `exec://` — Shell Command

Runs a shell command and captures stdout. Trailing newlines are stripped (shell `$()` semantics). Any non-zero exit from the command causes hydration to abort.

```dotenv
DB_PASSWORD=exec://aws secretsmanager get-secret-value \
  --secret-id prod/db-password --query SecretString --output text
```

> **Security note:** the command runs with the caller's shell privileges and may be visible in `ps` while running. See [Security Considerations](#security-considerations).

### `file://` — File Contents

Reads a file from the local filesystem. Useful with Docker secrets (`/run/secrets/`) or any file written by a bootstrap script.

```dotenv
SIGNING_KEY=file:///run/secrets/signing-key
TLS_CERT=file:///etc/ssl/private/app.pem
```

Hydration fails if the file is absent.

## Provider Contract

The provider system is defined in `lib/secrets_providers.sh`. Adding a new provider means defining two functions and registering the scheme.

### Required: resolver function

```bash
secrets_provider__<scheme>() {
  local target="$1"   # the part after <scheme>://

  # ... resolve the secret ...

  printf '%s' "$resolved_value"   # print to stdout — no trailing newline
  # call fail "..." to abort hydration on error
}
```

Rules:
- `$1` receives the target string (everything after `://`).
- Print the resolved value to **stdout only** — any diagnostic output must go to stderr.
- Return non-zero (or call `fail`) to abort the entire hydration run.
- Do **not** add a trailing newline to the output; the hydrator strips it anyway.

### Optional: pre-flight check function

```bash
secrets_provider__<scheme>_check() {
  if ! command -v my-cli >/dev/null 2>&1; then
    fail "secrets: 'my-cli' not found — install it to use <scheme>:// references"
    return 1
  fi
  if [ -z "${MY_CLI_TOKEN:-}" ]; then
    fail "secrets: MY_CLI_TOKEN not set — run: export MY_CLI_TOKEN=..."
    return 1
  fi
  return 0
}
```

When defined, `secrets_provider_available <scheme>` calls this before any resolution begins. If it returns non-zero, hydration stops before touching the filesystem. Providers without a `_check` function are assumed ready.

### Registering the scheme

Append the scheme name to `SECRETS_PROVIDERS` (space-separated):

```bash
export SECRETS_PROVIDERS="vault exec file op"
```

Or extend it inline when calling hydrate:

```bash
SECRETS_PROVIDERS="vault exec file op" strut myapp secrets hydrate --env prod
```

Only schemes in this list are treated as references. Unregistered schemes pass through as literal values.

## Adding a New Provider: 1Password Example

This walkthrough adds an `op://` provider using the [1Password CLI](https://developer.1password.com/docs/cli/).

**Template usage:**

```dotenv
DB_PASSWORD=op://Private/my-db/password
API_TOKEN=op://Team/api-token/credential
```

**Provider implementation** (e.g. in a project-local `strut-providers.sh`):

```bash
#!/usr/bin/env bash
# Custom 1Password provider for strut secrets hydrate

secrets_provider__op_check() {
  if ! command -v op >/dev/null 2>&1; then
    fail "secrets: '1Password CLI (op)' not found — install from https://1password.com/downloads/command-line/"
    return 1
  fi
  if ! op whoami >/dev/null 2>&1; then
    fail "secrets: not signed in to 1Password — run: eval \$(op signin)"
    return 1
  fi
  return 0
}

secrets_provider__op() {
  local ref="$1"   # e.g. "Private/my-db/password"
  local val
  if ! val=$(op read "op://$ref" 2>/dev/null); then
    fail "secrets: 1Password reference not found: op://$ref"
    return 1
  fi
  printf '%s' "$val"
}
```

**Wiring it in:**

```bash
# Source the provider definitions, then hydrate
source ./strut-providers.sh
SECRETS_PROVIDERS="vault exec file op" strut myapp secrets hydrate --env prod
```

Or wrap in a project script:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/strut-providers.sh"
export SECRETS_PROVIDERS="vault exec file op"
exec strut "$@"
```

## `exec://` as an Escape Hatch

`exec://` lets you call any secrets CLI without writing a dedicated provider. Use it when you need a one-off integration or the CLI already handles auth well.

### AWS Secrets Manager

```dotenv
DB_PASSWORD=exec://aws secretsmanager get-secret-value \
  --secret-id prod/db-password \
  --query SecretString \
  --output text

# JSON secret — extract a field with jq
API_KEY=exec://aws secretsmanager get-secret-value \
  --secret-id prod/api-keys \
  --query SecretString \
  --output text | jq -r '.api_key'
```

Requires: `aws` CLI, `AWS_PROFILE` or `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` set.

### GCP Secret Manager

```dotenv
DB_PASSWORD=exec://gcloud secrets versions access latest \
  --secret=prod-db-password \
  --project=my-gcp-project
```

Requires: `gcloud` CLI authenticated (`gcloud auth login` or service account).

### 1Password CLI (`op read`)

```dotenv
DB_PASSWORD=exec://op read op://Private/my-db/password
JWT_SECRET=exec://op read op://Team/jwt-secret/credential
```

Requires: `op` CLI and `eval $(op signin)`.

### Doppler CLI

```dotenv
DB_PASSWORD=exec://doppler secrets get DB_PASSWORD --plain
API_TOKEN=exec://doppler secrets get API_TOKEN --plain --project myapp --config prd
```

Requires: `doppler` CLI and `doppler setup` or `DOPPLER_TOKEN`.

## Security Considerations

### `exec://` trust model

`exec://` runs arbitrary shell commands with the **caller's full privileges**. This is intentional — it's what makes it useful as an escape hatch — but it means you should only hydrate templates you authored or have reviewed.

- The command string appears in `ps` output while running.
- Piped commands (`cmd1 | cmd2`) run in a subshell started by `bash -c`.
- Multi-line or complex commands should be wrapped in a helper script and called via `exec://my-helper.sh`.

**Do not hydrate a template you didn't write.**

### Template trust

Treat `.env.template` files the same way you treat shell scripts: they can execute code via `exec://`. Before hydrating a template from an untrusted source (e.g. a forked repo), audit every `exec://` reference.

### File permissions

The output `.env` file is written with mode `0600` (owner read/write only). The write is atomic — strut writes to a temp file in the same directory, then renames it, so a partial write never leaves a truncated file.

### Value safety

Resolved values that contain newlines cause hydration to abort, because multi-line values break `.env` file format. This prevents silently malformed output.

### No value logging

strut never prints resolved secret values to stdout or stderr. The `--dry-run` flag shows which references would be resolved and through which provider, without fetching any values.

## Lifecycle Integration

```
strut <stack> init-secrets --env prod     # Generate .env with random placeholders
strut <stack> secrets hydrate --env prod  # Populate from external manager (uses providers)
strut <stack> secrets validate --env prod # Check required_vars coverage
strut <stack> secrets push --env prod     # Upload .env to VPS (mode 600)
strut <stack> secrets diff --env prod     # Compare local vs remote key names (no values)
strut <stack> secrets pull --env prod     # Download .env from VPS
strut <stack> secrets status --env prod   # Show local/remote/template/key state
```

## Related

- `lib/secrets_providers.sh` — provider registry and built-in implementations
- `lib/cmd_secrets.sh` — hydrate, push, pull, diff, validate, status
- `.kiro/specs/secrets-lifecycle/` — design spec and requirements
- [CLI Reference](https://github.com/gfargo/strut/wiki/CLI-Reference) — full command flags
