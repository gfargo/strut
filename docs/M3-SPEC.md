# M3 — Foundational Refactors: Implementation Spec

> Milestone: [M3](https://github.com/gfargo/strut/milestone/3)
> Status: Planning
> Depends on: M2 (complete as of v0.30.4)

---

## Overview

M3 eliminates four classes of structural debt that block fleet-wide features (M4). Each issue produces a reusable primitive other commands inherit.

| # | Issue | Deliverable | Effort |
|---|-------|-------------|--------|
| 1 | #256 | `resolve_connection` + `parse_host_spec` | Medium |
| 2 | #255 | Usage/completions/handler reconciliation | Small |
| 3 | #251 | Unified env-edit path (`secrets` + `keys env:*`) | Medium |
| 4 | #248 | Shared comparison engine (drift/diff/doctor) | Large |

Recommended order: **#256 → #251 → #255 → #248** (each builds on the prior).

---

## 1. Host-Spec Resolver + `resolve_connection` (#256)

### Problem

The `user@host:port key` host spec is hand-parsed in 6+ places. Connection resolution (VPS_HOST/USER/PORT/KEY/DEPLOY_DIR) is copy-pasted ~8× with subtle precedence bugs. No per-host `deploy_dir` exists.

### Design

**New file:** `lib/connection.sh`

```bash
# parse_host_spec "ubuntu@10.0.0.1:2222 ~/.ssh/key deploy_dir=/opt/stacks"
# → sets: _HS_USER _HS_HOST _HS_PORT _HS_KEY _HS_DEPLOY_DIR
parse_host_spec() { ... }

# resolve_connection <stack> <env_name> [--host <alias>]
# Precedence: CLI --host > topology [stacks] > env file
# Sets+exports: VPS_HOST VPS_USER VPS_PORT VPS_SSH_KEY VPS_DEPLOY_DIR
resolve_connection() { ... }
```

### Tasks

1. **Create `lib/connection.sh`** with `parse_host_spec` + `resolve_connection`
2. **Extend `[hosts]` schema** to support optional `deploy_dir=<path>` field
3. **Replace inline parsers** in: `topology.sh` (×2), `cmd_gateway.sh`, `cmd_cert.sh`, `cmd_provision.sh`, `cmd_sync.sh`
4. **Replace ad-hoc connection blocks** in `cmd_secrets.sh` (5×), `debug.sh`, `backup.sh` (2×) with `resolve_connection`
5. **Unit test** `parse_host_spec` with property tests (hostile characters, missing fields, custom deploy_dir)
6. **Unit test** `resolve_connection` precedence: CLI > topology > env file

### Acceptance

- All host-scoped commands share one parser
- `sync` works for a `deploy@harbor` host with a custom deploy dir
- `resolve_connection` is unit-tested with 100-iteration property tests

---

## 2. Reconcile Usage / Completions / Handlers (#255)

### Problem

`--help` output, shell completions, and the dispatch table disagree — users can't discover commands.

### Design

**Single source of truth:** a structured command table in `lib/commands.sh` that generates usage + completions.

```bash
# lib/commands.sh — canonical command registry
# Format: "command|description|requires_stack|subcommands"
STRUT_COMMANDS=(
  "deploy|Deploy stack containers|yes|"
  "release|Full VPS release|yes|"
  "secrets|Manage secrets|yes|push,pull,diff,validate,hydrate,status,lock,unlock,rotate,template,export,set"
  ...
)
```

### Tasks

1. **Audit** all dispatched commands vs usage vs completions — produce a delta list
2. **Create `lib/commands.sh`** with the canonical registry array
3. **Rewrite `_usage_main()`** to generate from the registry
4. **Rewrite completion generators** (bash/zsh/fish in `completions/`) to read from the registry
5. **Add missing commands** to usage: `hydrate`, `prune`, `logs:download`, `logs:rotate`, `drift`, `ship`, `init-secrets`, `gateway`, `cert:*`, `provision`, `ssh:keygen`, `ci:init`, `sync`
6. **Fix `action.yml`** version default (track VERSION file or latest tag)
7. **Add a sync test** that asserts completions ⊇ dispatch cases ⊇ usage listed commands

### Acceptance

- `--help`, completions, and the dispatch table match
- The sync test passes in CI
- `action.yml` references the current version

---

## 3. Unify `secrets *` and `keys env:*` (#251)

### Problem

Two parallel env-editing subsystems with divergent quality: `secrets *` (env-aware, masks values, atomic writes, chmods) vs `keys env:*` (hardcoded `.prod.env`, prints values, sed-based edits, leaks secrets in diff).

### Design

**Consolidate on the `secrets`-side quality bar.** `keys env:*` becomes thin wrappers calling shared primitives.

**Shared primitives** (already partially exist):
- `safe_load_env` (done, v0.30.4)
- `_secrets_write_var` (exists, atomic + chmod 600)
- `_secrets_render_env_diff` (exists, masks values)

**Migration path:**
- `keys env:rotate` → calls `_secrets_write_var` (already does after our fix)
- `keys env:set` → delegates to `secrets set` internally
- `keys env:diff` → delegates to `secrets diff` (masked output)
- Remove duplicated sed-based edit paths

### Tasks

1. **Extract shared env primitives** into `lib/env.sh`: `env_read_var`, `env_write_var` (atomic, chmod 600), `env_diff` (masked), `env_resolve_path` (stack+env-aware)
2. **Refactor `cmd_secrets.sh`** to use `lib/env.sh` primitives
3. **Refactor `lib/keys/env.sh`** to use the same primitives (no more inline sed)
4. **Make `keys env:*` env-aware** — honor `--env <name>` instead of hardcoding `.prod.env`
5. **Ensure `keys env:diff` masks values** like `secrets diff` does
6. **Remove temp file usage** in keys rotation (currently uses `/tmp`)
7. **Test** that `secrets set` and `keys env:set` produce identical file states

### Acceptance

- One code path handles env reads/writes/diffs with consistent masking and permissions
- `keys env:*` works with `--env staging` (not hardcoded to prod)
- No secret values appear in `keys env:diff` output

---

## 4. Shared Comparison Engine (#248)

### Problem

Six inspection commands answer "does reality match intent?" with different notions of reality. `drift` uses broken hashing (echo adds newline), compares wrong paths, and is blind to env/untracked-file drift.

### Design

**Core primitive:** `lib/compare.sh`

```bash
# compare_file_remote <local_path> <remote_path> <ssh_opts> <user@host>
# Returns: "match" | "diverged" | "missing-local" | "missing-remote"
# Side effect: populates COMPARE_DIFF with unified diff
compare_file_remote() { ... }

# compare_env_remote <local_env> <remote_env_path> <ssh_opts> <user@host>
# Returns: normalized KEY diff (values masked)
compare_env_remote() { ... }

# compare_hash_remote <local_path> <remote_path> <ssh_opts> <user@host>
# Returns: 0 if hashes match, 1 if not
# Uses: sha256sum on raw file bytes (no echo wrapping)
compare_hash_remote() { ... }
```

**Phase 1:** Fix drift's hashing + point it at the real deploy dir (via `resolve_connection`)
**Phase 2:** Extract `lib/compare.sh` from `lib/diff.sh` (which is already 80% there)
**Phase 3:** Migrate `drift detect` to use compare primitives
**Phase 4:** Migrate `doctor` deploy-dir checks to use compare primitives

### Tasks

1. **Fix drift hashing** — replace `echo "$(git show ...)" | sha256sum` with `git show ... | sha256sum` (no trailing newline injection)
2. **Fix drift deploy-dir** — use `resolve_connection` to get the real remote path instead of hardcoded `~/strut/stacks`
3. **Extract `lib/compare.sh`** from the existing `lib/diff.sh` (which already has `diff_fetch_remote`, `diff_env_content`, `diff_detect_destructive`)
4. **Add `compare_hash_remote`** — SHA256 comparison without the echo bug
5. **Migrate `drift detect`** to use `compare_hash_remote` + `resolve_connection`
6. **Add env-layer drift** — `compare_env_remote` detects when host env ≠ committed env
7. **Add untracked-stack detection** — compare `docker ps` project labels vs `stacks/*`
8. **Graceful config-only stacks** — `drift detect` returns "not-applicable" instead of crashing when no compose file exists
9. **Unit test** the hashing fix (file without trailing newline → hashes match)
10. **Unit test** compare primitives with mocked SSH

### Acceptance

- `drift` and `diff` agree on the same repo/host state
- A file without a trailing newline no longer reports as drifted
- Config-only stacks don't crash `drift detect`
- Env drift is reported
- `#182` sub-bugs resolved by construction

---

## Dependency Graph

```
#256 (resolve_connection)
  ↓
#251 (unified env-edit) ← uses resolve_connection for env path resolution
  ↓
#255 (usage/completions) ← can reference new unified command surface
  ↓
#248 (comparison engine) ← uses resolve_connection + unified env primitives
```

## Rollout Plan

Each issue ships as its own PR with tests. CI must stay green between merges.

1. **#256** — `lib/connection.sh` (no breaking changes, additive + replacements)
2. **#251** — `lib/env.sh` extraction (internal refactor, no CLI change)
3. **#255** — Usage/completions sync (visible to users, no behavior change)
4. **#248** — Comparison engine (fixes drift bugs, visible behavior improvement)

After M3, the fleet-status command (#257) and multi-host deploys (#188) become straightforward feature work on top of these primitives.
