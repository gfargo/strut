# www Release Sync - Design

## Overview

A single GitHub Actions workflow, `.github/workflows/deploy-www.yml`, POSTs to a
Vercel Deploy Hook when a strut release is published (or on manual dispatch).
The hook triggers a production build of `strut-www`; that build's existing
`prebuild` step regenerates the version badge. No other moving parts.

```
release-please merges release PR
        │  creates GitHub Release (authored by RELEASE_PLEASE_TOKEN)
        ▼
on: release [published]  ──►  deploy-www.yml
        │                         │  POST $VERCEL_WWW_DEPLOY_HOOK
        │                         ▼
        │                    Vercel builds strut-www
        │                         │  prebuild: scripts/fetch-version.js
        │                         │  → GET api.github.com/.../releases/latest
        │                         ▼
        └──────────────►  lib/version.json regenerated → site shows new version
```

## Architecture

### Why a Deploy Hook (vs. commit / Vercel CLI / repository_dispatch)

`strut-www` already regenerates `lib/version.json` on every build from
`releases/latest`. The only thing missing is a build trigger. Given that:

- **Deploy Hook** — a single POST-able URL, stored as one repo secret. No token
  with write access to `strut-www`, no Vercel API token, no cross-repo commit.
  Lowest privilege, least coupling. **Chosen.**
- *Commit `version.json` to strut-www* — would need a cross-repo write token and
  is redundant: the prebuild overwrites `version.json` on the next build anyway.
- *`vercel deploy` via CLI* — needs a broader `VERCEL_TOKEN` plus project/org
  IDs; more setup and scope than a hook.
- *`repository_dispatch` to strut-www* — needs a dispatch token AND a receiving
  workflow in strut-www; more surface for the same result.

### Trigger events

- `release: [published]` — the primary trigger. Guarded so prereleases/drafts
  don't deploy (Requirement 1.3).
- `workflow_dispatch` — manual redeploy button (Requirement 2). No release
  context, so the prerelease guard must treat "no release" as allowed.

### The RELEASE_PLEASE_TOKEN constraint (carried from release-please.yml)

GitHub deliberately suppresses workflow triggering for events authored by the
default `GITHUB_TOKEN` (anti-recursion). release-please.yml already documents
this and uses `RELEASE_PLEASE_TOKEN || GITHUB_TOKEN` so its releases are
authored by a real actor and thus wake `on: release` workflows (this is what
makes `homebrew.yml` fire). `deploy-www.yml` relies on the same setup — it is a
peer of `homebrew.yml`. The workflow header documents this so the dependency is
discoverable.

## Components and Interfaces

### `.github/workflows/deploy-www.yml`

```yaml
on:
  release:    { types: [published] }
  workflow_dispatch:

permissions:
  contents: read            # least privilege (Requirement 4.3)

jobs:
  deploy-www:
    # Skip prereleases/drafts on the release path; always allow manual dispatch.
    if: github.event_name == 'workflow_dispatch' || github.event.release.prerelease == false
    runs-on: ubuntu-latest
    steps:
      - Trigger strut-www Vercel deploy   # single bash step (see below)
```

### The trigger step (contract)

- Reads the hook from `env.HOOK` (`${{ secrets.VERCEL_WWW_DEPLOY_HOOK }}`) — a
  secret is not usable in a step `if:`, so the empty-secret guard lives in the
  script (Requirement 3.1).
- If `HOOK` is empty → print an actionable `::warning::` with setup steps and
  `exit 0` (green).
- Validate the hook is an `https://` URL (defense against a mis-pasted secret).
- `curl -sS -X POST "$HOOK"`, capturing HTTP status and body.
- 2xx → success (Vercel returns `201 Created`); any other status → `::error::`
  and non-zero exit (Requirement 1.4).
- Log the release tag (or "manual dispatch") for traceability.

## Data Models

No persisted data. The only interface is the Vercel Deploy Hook:

- **Request:** `POST <hook-url>` (empty body accepted).
- **Response:** JSON `{ "job": { "id", "state", ... } }`, HTTP `201` on success.
- **Secret:** `VERCEL_WWW_DEPLOY_HOOK` — created in the strut-www Vercel project
  (Settings → Git → Deploy Hooks), bound to the production branch. Stored as a
  repo secret in `gfargo/strut`.

## Error Handling

- **Secret unset/empty** → warning + `exit 0` (safe to merge before setup).
- **Non-https hook** → `::error::` + non-zero exit (mis-pasted secret caught
  early, and avoids POSTing a secret to a plaintext endpoint).
- **Non-2xx from Vercel** → `::error::` with the status + body, non-zero exit,
  so the failure is visible in the Actions tab.
- **Prerelease/draft release** → job `if:` skips the whole job (no deploy).
- **Transient network failure** → `curl -sS --retry 3 --retry-delay 5` gives a
  few automatic retries before failing.

## Testing Strategy

GitHub Actions workflows can't run under the repo's `bats` suite, so validation
is static + manual:

- **YAML / workflow lint** — `actionlint` (if available) or a YAML parse over
  `deploy-www.yml`; the repo's existing `test_github_action.bats` covers
  `action.yml`, not workflows, so this is a lint-level check.
- **Shell step lint** — the trigger step's script passes `shellcheck` (extracted
  or reviewed inline); `bash -n` on the script body.
- **Guard behavior** — exercised by running the step's script locally with
  `HOOK` unset (expect warning + exit 0), with a non-https `HOOK` (expect error),
  and with a stub endpoint returning 201 (expect success) / 500 (expect error).
- **End-to-end (post-merge, manual)** — after the `VERCEL_WWW_DEPLOY_HOOK`
  secret is set, run the workflow via `workflow_dispatch` and confirm a
  strut-www deploy starts in Vercel and the site's badge updates. This is the
  real "it works" gate and is documented in `tasks.md`.
