# Deployment

Procedures for deploying strut services to a VPS.

## Quick Deploy

```bash
strut my-stack release --env prod --dry-run   # Preview
strut my-stack release --env prod             # Full release
```

`release` runs on the VPS over SSH and automatically: updates the repo → runs migrations → deploys → verifies health.

## Manual Deploy Steps

```bash
strut my-stack update --env prod              # Sync strut repo on VPS
strut my-stack deploy --env prod              # Deploy containers
strut my-stack health --env prod --json       # Verify
```

## Stop Containers

```bash
strut my-stack stop --env prod                # Stop containers
strut my-stack stop --env prod --volumes      # Stop + remove volumes
strut my-stack stop --env prod --dry-run      # Preview
```

## Service Profiles

```bash
strut my-stack deploy --env prod                          # core (default)
strut my-stack deploy --env prod --services messaging     # + messaging
strut my-stack deploy --env prod --services full          # everything
```

## Deploy Modes

```bash
strut my-stack deploy --env prod --standard     # in-place (default)
strut my-stack deploy --env prod --blue-green    # stand up green, health-gate, swap, drain blue
```

## First-Time Setup

1. Create an env file from the template, fill in secrets (`VPS_HOST`, registry creds, DB passwords).
2. Configure `strut.conf` with registry type and org.
3. Deploy: `strut my-stack release --env prod`.

## Migrations

```bash
strut my-stack migrate postgres --status --env prod   # Check
strut my-stack migrate postgres --up --env prod       # Apply
strut my-stack migrate neo4j --down 1 --env prod      # Rollback one
```

## Rollback

```bash
strut my-stack rollback --env prod            # Restore previous deploy snapshot
```

## Deploy History / Releases

Every deploy and release appends a durable, structured record (timestamp,
git SHA, deploy mode, env, outcome, and — for `release` — the actor who
triggered it) to `stacks/<stack>/.deploy-history.jsonl`, alongside the
existing rollback snapshot in `stacks/<stack>/.rollback/`.

```bash
strut my-stack releases --env prod                     # List past deploys/releases, newest first
strut my-stack releases --env prod --json --limit 20    # For CI/automation
strut my-stack releases show HEAD --env prod            # Full detail for the latest release
strut my-stack releases show 20260420-091500 --env prod # Full detail for a specific release
```

`releases show <id>` accepts the same refs as `rollback diff`: a release ID
(the rollback snapshot basename), `HEAD` (latest), or `HEAD~N` (Nth older) —
release IDs and rollback snapshot IDs share the same ID space, so:

```bash
strut my-stack releases --env prod                      # Find the release you're investigating
strut my-stack rollback diff HEAD~1 HEAD --env prod      # Compare it against the one before
```

Note: a release's `release_id` is the snapshot captured *before* that
release ran — i.e. what `rollback` (which always restores the latest
snapshot) would put back if run right after that release, not a snapshot
of what that release itself deployed. For the same reason, `releases show`
labels its per-service image list "Rollback-to images (pre-release state)"
(`rollback_images` in `--json` output) rather than "Images" — they're the
tags that release would revert to, not the tags it shipped.

## Local vs VPS Semantics

- `deploy` / `stop` — runs locally, or on the VPS if `VPS_HOST` is set
- `release` — always runs on the VPS via SSH
- `update` — syncs the strut repo on the VPS (no container restart)
- `shell` / `exec` — SSH to the VPS

## Best Practices

1. Always `--dry-run` first for destructive commands.
2. Back up before major changes: `strut my-stack backup all --env prod`.
3. Use `release` for VPS deploys (runs remotely), not `deploy` (runs locally).
4. Keep `services.conf` health checks current — they gate deploy success.
