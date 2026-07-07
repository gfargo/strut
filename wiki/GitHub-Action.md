# GitHub Action

Deploy a strut-managed Docker stack to a VPS from GitHub Actions in one step.

```yaml
- uses: gfargo/strut-action@v1
  with:
    stack: my-app
    command: release
    env: prod
    host: ${{ secrets.STRUT_HOST }}
    ssh-key: ${{ secrets.STRUT_SSH_KEY }}
```

---

## Prerequisites

1. Your repository contains `strut.conf` and a `stacks/<stack>/` directory (run `strut init` + `strut scaffold <stack>` locally first).
2. The VPS already has strut bootstrapped (`strut remote:init` or manual setup).
3. Two repository secrets are configured (**Settings → Secrets and variables → Actions**):
   - `STRUT_HOST` — VPS hostname or IP address
   - `STRUT_SSH_KEY` — Private SSH key whose public half is in `~/.ssh/authorized_keys` on the VPS

The workflow must `actions/checkout` before the strut action so `strut.conf` and the `stacks/` tree are present on the runner.

---

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `stack` | ✓ | — | Stack name (subdirectory under `stacks/`) |
| `command` | | `release` | strut command — see [Command semantics](#command-semantics) |
| `env` | | `prod` | Environment name — resolves to `.<env>.env` in the project root |
| `host` | ✓ | — | VPS hostname or IP (`VPS_HOST`) — use a secret |
| `ssh-key` | ✓ | — | Private SSH key contents (`VPS_SSH_KEY`) — use a secret |
| `ssh-port` | | `22` | SSH port on the VPS (`VPS_PORT`) |
| `user` | | `ubuntu` | SSH user on the VPS (`VPS_USER`) |
| `deploy-dir` | | `/home/<user>/strut` | Deployment directory on the VPS (`VPS_DEPLOY_DIR`) |
| `services` | | — | Services profile passed as `--services <profile>` |
| `strict` | | `false` | Pass `--strict` — treat migration failures as fatal |
| `dry-run` | | `false` | Pass `--dry-run` — print the plan without making changes |
| `version` | | `main` | strut tag to install — pin to a release tag for reproducible deploys |
| `env-vars` | | — | Extra `KEY=VALUE` pairs, one per line (e.g. `GH_PAT`, registry tokens) |

---

## Minimal example

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: gfargo/strut-action@v1
        with:
          stack: my-app
          host: ${{ secrets.STRUT_HOST }}
          ssh-key: ${{ secrets.STRUT_SSH_KEY }}
```

---

## Full example

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      dry-run:
        description: 'Preview without deploying'
        default: 'false'
        type: boolean

jobs:
  deploy:
    runs-on: ubuntu-latest
    concurrency:
      group: deploy-prod
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4

      - uses: gfargo/strut-action@v1
        with:
          stack: my-app
          command: release
          env: prod
          host: ${{ secrets.STRUT_HOST }}
          ssh-key: ${{ secrets.STRUT_SSH_KEY }}
          version: v0.31.0          # pin to a specific strut release
          strict: true              # fail on migration errors
          dry-run: ${{ github.event.inputs.dry-run || 'false' }}
          env-vars: |
            GH_PAT=${{ secrets.GH_PAT }}
```

> **Note:** `strut health` runs against the runner's local Docker daemon, not the VPS. It cannot verify stack health on a hosted runner. To check the VPS after release, use your own smoke-test step (e.g. `curl` the health endpoint) or run `strut <stack> status` over SSH.

---

## Command semantics

| Command | Runs where | Use case |
|---------|-----------|---------|
| `release` | Runner (SSH to VPS) | **Primary CI command.** Runs update → migrate → deploy → verify on the VPS over SSH. |
| `ship` | Runner (git + SSH to VPS) | Like `release` but also commits and pushes from the runner. Needs `contents: write` permission and full checkout. **See security warning below.** Prefer `release` in most CI pipelines. |
| `health` | **Runner's local Docker** | Checks `docker compose ps` on the runner — **not the VPS**. Not useful on a hosted runner (Docker is empty). Omit from hosted CI; use a smoke-test curl or SSH step instead. |
| `deploy` | **VPS only** | Starts containers locally. Has an interactive prompt when `VPS_HOST` is set, which **will hang a hosted runner**. Only use with a self-hosted runner that is the VPS itself. |

> **Rule of thumb:** use `release` from a hosted runner. Use `deploy` or `health` only on a self-hosted runner running on the VPS itself.

### Security warning: `command: ship`

`ship` runs `git add -A` on the runner before pushing. The action writes a `.<env>.env` file (containing `VPS_HOST` and any `env-vars`) to the repository root. **If your repo does not gitignore `*.env`, this file will be committed and pushed, leaking secrets.**

Before using `command: ship`:
1. Add `*.env` (or `.prod.env`, `.staging.env`, etc.) to your repo's `.gitignore`.
2. Confirm the gitignore is committed before the workflow runs.

For hosted CI, **`release` is the safe default** — it does not run any `git` commands on the runner.

---

## Pinning the strut version

Use the `version` input to pin to a specific release tag, ensuring reproducible deploys:

```yaml
- uses: gfargo/strut-action@v1
  with:
    version: v0.28.0
    # ...
```

The action installs strut at that tag and logs the version to the action output.

---

## Passing extra secrets (registry tokens, etc.)

The `env-vars` input accepts newline-separated `KEY=VALUE` pairs written to the env file before the strut command runs:

```yaml
- uses: gfargo/strut-action@v1
  with:
    env-vars: |
      GH_PAT=${{ secrets.GH_PAT }}
      REGISTRY_TOKEN=${{ secrets.REGISTRY_TOKEN }}
    # ...
```

These are written to the `.prod.env` file (or whichever `env` you chose) and never echoed to the action log.

---

## Security notes

- The SSH key is written to `$RUNNER_TEMP/strut_deploy_key` with mode `600` and never printed.
- The env file is written with mode `600`. Values are materialized via `printf`, not `echo`.
- `VPS_HOST` is masked in the action log with `::add-mask::`.
- Secrets passed as `${{ secrets.* }}` are automatically redacted by GitHub Actions.
- strut uses `StrictHostKeyChecking=accept-new` by default (TOFU model — accepts on first connection, rejects if key changes). Override with `STRUT_SSH_HOST_KEY_CHECK=no` for legacy behavior.
- `--dry-run` shows the SSH plan (host/user only) without leaking key or env values.

---

## Troubleshooting

**`strut: command not found` after install**
Install adds a symlink to `/usr/local/bin` (writable on hosted runners) or `~/.local/bin`. If the `Verify strut version` step fails, the runner environment may be unusual — open an issue with the runner OS and version.

**`Not inside a strut project`**
The runner must have `strut.conf` at the repo root. Ensure `actions/checkout` runs before this action.

**`Stack not found`**
The `stack` input must match a directory under `stacks/` in your repository.

**Release hangs or fails on SSH**
Verify `STRUT_HOST` resolves, port `22` (or your `ssh-port`) is open, and the public key matching `STRUT_SSH_KEY` is in `~/.ssh/authorized_keys` on the VPS.

**`deploy` hangs in CI**
Use `release` instead. The `deploy` command has an interactive prompt when run from a hosted runner with `VPS_HOST` set. See [Command semantics](#command-semantics).
