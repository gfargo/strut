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

After merging PRs:

```bash
git checkout main && git pull origin main
# Bump VERSION file (semver: major.minor.patch)
git add VERSION && git commit -m "chore: bump version to X.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z: <summary>"
git push origin main --tags
gh release create vX.Y.Z --title "vX.Y.Z: <Title>" --notes-file .release-notes.md
```

Use temp files (`.pr-body.md`, `.release-notes.md`) for long content — delete after use.

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
- `shellcheck` in CI is stricter than local (treats warnings as errors)
- Wiki uses `master` branch, main repo uses `main`

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
