---
inclusion: auto
keywords: ["issue", "pr", "test", "release", "version", "branch", "commit", "github", "wiki", "feature"]
description: "Development workflow patterns for contributing to strut"
---

# strut Development Workflow

## Branch & PR Pattern

Every change follows: branch → implement → test → commit → push → PR → merge → release.

```bash
git checkout main && git pull origin main
git checkout -b <feature-name>
# ... implement ...
bats tests/                                    # Verify all tests pass
shellcheck -s bash strut lib/<file>.sh         # Lint
git add <files> && git commit -m "<type>: <description>\n\nCloses #<N>"
git push origin <feature-name>
gh pr create --base main --head <feature-name> --title "<type>: <desc>" --body-file .pr-body.md
```

Commit types: `feat`, `fix`, `refactor`, `test`, `chore`, `docs`

## Release Pattern

Releases are automated by [release-please](https://github.com/googleapis/release-please) (`.github/workflows/release-please.yml`, `release-please-config.json`, `.release-please-manifest.json`). There is no manual `VERSION` bump, tag, or `gh release create` step anymore:

1. PRs merge to `main` as usual — squash-merged, PR title in conventional-commit format (`fix(scope): ...`, `feat(scope): ...`, `chore: ...`). release-please reads these commits directly off `main`.
2. On every push to `main`, the `release-please` workflow opens (or updates) a standing **release PR** containing the generated changelog entry and the next `VERSION` bump — patch for `fix`, minor for `feat` (project is pre-1.0, so `feat` bumps minor, not major).
3. When you're ready to ship, merge that release PR like any other. That merge is the trigger: release-please tags the commit `vX.Y.Z` and publishes the GitHub release.
4. Publishing the release fires the existing `homebrew.yml` workflow, which updates the `gfargo/homebrew-tap` formula automatically — no separate step needed.

If a fix needs to skip the queue and ship alone, just merge only its release PR (release-please batches whatever's landed on `main` since the last release into one PR, so it's fine to merge the release PR right after a single urgent fix rather than waiting for a batch).

Use temp files (`.pr-body.md`) for long PR bodies — delete after use.

## Adding a New Command

1. Create `lib/cmd_<name>.sh` with:
   - `_usage_<name>()` function for `--help` support
   - `cmd_<name>()` handler reading from `CMD_*` exports
2. Source it in the `strut` entrypoint
3. Add to help dispatch (`_has_help_flag` case)
4. Add to command dispatch (`case "$COMMAND"`)
5. Create `tests/test_<name>.bats`
6. Update wiki CLI Reference

## Command Handler Signature

All handlers read context from exported `CMD_*` variables:

```bash
cmd_example() {
  local stack="$CMD_STACK"
  local stack_dir="$CMD_STACK_DIR"
  local env_file="$CMD_ENV_FILE"
  local env_name="$CMD_ENV_NAME"
  local services="$CMD_SERVICES"
  local json_flag="$CMD_JSON"
  # $@ contains only command-specific args
}
```

## Adding a New Config Key

1. Add default in `lib/config.sh` → `load_strut_config()`
2. Add to the `export` line
3. Add commented entry to `templates/strut.conf.template`
4. Update `lib/cmd_validate.sh` if it needs validation
5. Update wiki Configuration page

## Test Patterns

- Unit tests: `tests/test_<module>.bats`
- Property tests: 100 iterations with randomized inputs
- Tests that call handlers directly must set `CMD_*` exports
- Use `run` for functions that may fail under `set -e`
- Avoid `eval` and `[ -n "$x" ] && cmd` patterns (fail under `set -e`)
- Use `if [ -n "$x" ]; then cmd; fi` instead

## Common Pitfalls

- `set -euo pipefail` means `[ -n "$x" ] && do_thing` exits on false — use `if` blocks
- `run` in BATS creates a subshell — exported vars from setup() are available but function-local state isn't
- macOS `stat` uses `-f` flags, Linux uses `-c` — always support both
- macOS doesn't have `timeout` — use `gtimeout` or skip
- macOS BSD `grep` doesn't support `-P` (Perl regex) — use `grep -Eo`, `awk`, or `sed` instead
- `shellcheck` in CI is stricter than local (treats warnings as errors)
- Wiki uses `master` branch, main repo uses `main`
- `fail()` in lib modules calls `exit 1`, but tests override it to `return 1` — always add `return 1` after `fail` in functions that need to work in both contexts

## Engine vs Project Separation

strut has two directory concepts:
- `STRUT_HOME` — where strut is installed (the engine: lib/, templates/, completions/)
- `CLI_ROOT` / `PROJECT_ROOT` — the user's project (stacks/, strut.conf, .env files)

When sourcing engine lib files from within lib modules, always use:
```bash
local strut_home="${STRUT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$strut_home/lib/some_module.sh"
```

Never use `$cli_root/lib/...` or `$CLI_ROOT/lib/...` for engine files — the project directory may not contain lib/.

## Topology & Multi-Host

The `[hosts]` and `[stacks]` sections in strut.conf are:
- Parsed by `lib/topology.sh` (its own line-by-line reader)
- Skipped by `preprocess_config` in `lib/config.sh` (so they don't get sourced as bash)

When adding new INI-style sections to strut.conf:
1. Add section detection to `_preprocess_config()` (skip the section)
2. Add a dedicated parser in the relevant module
3. Section content uses `key = value` (spaces around `=`) to distinguish from bash `KEY=value`

The `--host` flag overrides topology targeting per-invocation. Per-host env overrides live at `stacks/<stack>/.<host_alias>.env`.

## Issue-to-Release Workflow

For rapid iteration on bug reports and features:

```bash
# 1. Read the issue
# 2. Write a failing test (for bugs)
# 3. Fix the code
# 4. Verify tests pass + shellcheck clean
# 5. Branch → commit → push → PR → merge (single flow)
git checkout -b fix/short-name
git add <files> && git commit -m "fix: description. Closes #N"
git push -u origin fix/short-name
gh pr create --base main --head fix/short-name --title "..." --body-file .pr-body.md
gh pr merge --merge --delete-branch

# 6. release-please picks up the merged commit automatically and updates
#    its standing release PR — merge that PR when ready to ship (see
#    "Release Pattern" above). No manual VERSION bump/tag/release needed.
```

For PR bodies longer than a few lines, use `.pr-body.md` (temp file, delete after).

## Marketing Site (.www)

The `.www/` directory is a separate git repo (strut-www) deployed on Vercel.

Key maintenance tasks:
- **Version badge**: Run `node scripts/fetch-version.mjs` in `.www/` to update `lib/version.json`
- **Docs**: Auto-fetched from wiki via ISR (1hr revalidation) — no manual sync needed
- **Changelog**: `/changelog` page fetches from GitHub Releases API
- **After releases**: Push version update to `.www` repo to trigger Vercel redeploy

## Wiki Updates

The wiki is cloned into `wiki/` (gitignored from main repo):

```bash
# Edit pages
nano wiki/Page-Name.md

# Push changes
git -C wiki add -A && git -C wiki commit -m "msg" && git -C wiki push origin master
```

Update wiki when: adding commands, changing config, adding features, bumping version.

## Security Considerations

- Never use `eval` with user-controlled input (config files, env vars)
- Env files (`.prod.env`) must be gitignored — never committed
- SSH keys must be `600` permissions
- Secrets in config should be detected and warned about
- `--skip-validation` exists for emergencies but should be rare
