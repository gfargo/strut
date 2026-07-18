# www Release Sync - Requirements

## Introduction

The marketing site (`strut-www`, deployed on Vercel) shows the current strut
version in its hero, navbar, and docs header. That version is read from
`lib/version.json`, which is **regenerated at build time** by the site's
`prebuild` step (`scripts/fetch-version.js` fetches `releases/latest` from the
GitHub API). So the site is already designed to self-update — it just needs a
build to run.

The gap: nothing rebuilds `strut-www` when a new strut version is released.
Releases are cut by release-please in this repo; the site's Vercel project only
rebuilds when its own repo changes. The result is a version badge that drifts
(as of this writing the site shows `v0.35.1` while strut is at `0.40.1`).

This feature closes that gap with a single GitHub Actions workflow in the strut
repo that triggers a `strut-www` Vercel deploy whenever a release is published.
Because the site regenerates `version.json` on build, triggering the deploy is
all that's needed — no cross-repo commit, no change to `strut-www`.

## Requirements

### Requirement 1: Redeploy the site on every published release

**User Story:** As a maintainer, I want the marketing site to redeploy
automatically when I publish a new strut release, so that its version badge and
docs always reflect the latest release without a manual step.

#### Acceptance Criteria

1. WHEN a GitHub release is published in this repo THEN the workflow SHALL POST
   to the `strut-www` Vercel Deploy Hook, triggering a production rebuild.
2. WHEN the deploy is triggered THEN the site's `prebuild` (`fetch-version.js`)
   SHALL run as part of that build and regenerate `lib/version.json` from
   `releases/latest` — so the new version appears without any commit to
   `strut-www`.
3. WHEN the release is a prerelease or draft THEN the workflow SHALL NOT trigger
   a deploy (the site tracks the latest stable release only).
4. WHEN the Vercel Deploy Hook returns a non-2xx HTTP status THEN the workflow
   SHALL fail loudly, so a broken hook is visible in the Actions tab rather than
   silently skipped.

### Requirement 2: Manual trigger

**User Story:** As a maintainer, I want to redeploy the site on demand, so that
I can refresh it without cutting a release (e.g. after fixing the hook, or to
pull in a release whose event didn't fire).

#### Acceptance Criteria

1. WHEN I run the workflow from the Actions "Run workflow" button
   (`workflow_dispatch`) THEN it SHALL trigger the same Vercel deploy as a
   release event.
2. WHEN triggered manually THEN the prerelease guard SHALL NOT block it (there
   is no release context to inspect).

### Requirement 3: Safe to merge before the secret exists

**User Story:** As a maintainer, I want to merge this workflow before wiring up
the secret, so that the change is decoupled from the one-time Vercel setup.

#### Acceptance Criteria

1. WHEN the `VERCEL_WWW_DEPLOY_HOOK` secret is unset or empty THEN the workflow
   SHALL emit a warning explaining how to configure it and exit successfully
   (green), NOT fail — mirroring `release-please.yml`'s
   `RELEASE_PLEASE_TOKEN || GITHUB_TOKEN` fallback philosophy.
2. WHEN documenting the workflow THEN it SHALL note the `RELEASE_PLEASE_TOKEN`
   constraint: a release created by the default `GITHUB_TOKEN` does NOT trigger
   `on: release` workflows, so this workflow (like `homebrew.yml`) only fires
   for releases authored by a real token.

### Requirement 4: No changes to strut-www; least privilege

**User Story:** As a maintainer, I want the trigger to require the least
possible privilege and no coupling to the site's internals, so it's simple and
safe.

#### Acceptance Criteria

1. WHEN implementing the trigger THEN it SHALL require ONLY a single Deploy Hook
   URL secret — no write token to `strut-www`, no Vercel API token, and no
   commit into the site repo.
2. WHEN the site's version source changes in future THEN this workflow SHALL
   remain valid as long as a rebuild reflects the change (it only triggers a
   build; it does not encode where the version comes from).
3. WHEN the workflow requests permissions THEN it SHALL request only
   `contents: read`.
