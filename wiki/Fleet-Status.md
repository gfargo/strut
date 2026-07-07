# Fleet Status

Monitor the git sync state of all hosts in your fleet from one command.

## Overview

`strut fleet status` iterates every host defined in the `[hosts]` section of `strut.conf`, SSHes into each, and reports how far behind `origin/<branch>` the deployed checkout is.

```
$ strut fleet status

  HOST         BRANCH   BEHIND AHEAD  DIRTY HEAD
  ────         ──────   ────── ─────  ───── ────
  compass      main     0      0      0     a3f81c2
  harbor       main     3      0      1     e92d4f1
  watch        main     12     0      0     7c91ab8
```

## JSON Mode

For automation and monitoring integrations:

```bash
strut fleet status --json
```

```json
{
  "hosts": [
    {"host": "compass", "status": "ok", "branch": "main", "behind": "0", "ahead": "0", "dirty": 0, "head_sha": "a3f81c2..."},
    {"host": "harbor", "status": "ok", "branch": "main", "behind": "3", "ahead": "0", "dirty": 1, "head_sha": "e92d4f1..."}
  ],
  "branch": "main"
}
```

## How It Works

1. Reads host aliases from `[hosts]` in `strut.conf`
2. Parses each host spec using `parse_host_spec` (user@host:port key)
3. Resolves the deploy directory (from `deploy_dir=` in host spec, or default `/home/<user>/strut`)
4. Runs `fleet_git_status` via SSH on each host
5. Reports behind/ahead counts, dirty file count, and current HEAD

## Configuration

Fleet status reads from strut.conf topology:

```ini
[hosts]
compass = ubuntu@10.0.0.1:22 ~/.ssh/compass_key
harbor  = deploy@10.0.0.2:22 ~/.ssh/harbor_key deploy_dir=/opt/stacks
watch   = ubuntu@10.0.0.3

[stacks]
myapp = compass
redis = harbor
```

The `deploy_dir=` field is optional (new in v0.31.0). When omitted, defaults to `/home/<user>/strut`.

## Status Values

| Field | Meaning |
|-------|---------|
| BEHIND | Commits the host is behind `origin/<branch>` |
| AHEAD | Commits ahead of origin (local changes pushed directly) |
| DIRTY | Number of uncommitted modified/untracked files |
| HEAD | Short SHA of the current commit on the host |

Special values:
- `?` for behind/ahead — fetch failed (network, auth, or private repo without PAT)
- `unreachable` — SSH connection failed
- `missing` — deploy directory not found on host

## Bringing Hosts In Sync

When a host is behind, use `strut sync` to bring it current:

```bash
strut sync compass          # sync one host
strut sync --all            # sync all hosts
strut sync harbor --dry-run # preview what would change
```

## Related

- [`strut sync`](https://github.com/gfargo/strut/wiki/CLI-Reference) — bring host checkouts in sync with origin
- [`strut drift detect`](https://github.com/gfargo/strut/wiki/CLI-Reference) — detect config file drift
- [`strut drift images`](https://github.com/gfargo/strut/wiki/CLI-Reference) — detect stale container image digests
- [Topology & Multi-Host](https://github.com/gfargo/strut/wiki/Configuration) — `[hosts]` and `[stacks]` config reference
