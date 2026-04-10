# Contributing to strut

## Setup

```bash
git clone https://github.com/gfargo/strut.git
cd strut
```

No build step — it's all bash. You just need `shellcheck` and `bats` for linting and testing.

```bash
brew install shellcheck bats-core   # macOS
```

## Running Tests

```bash
bats tests/                    # all tests
bats tests/test_config.bats    # single file
```

## Linting

```bash
shellcheck -s bash strut
find lib -name '*.sh' -print0 | xargs -0 shellcheck -s bash
```

## Code Conventions

### Shell Modules (`lib/*.sh`)

- Start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Include a header comment: module name, description, dependencies, provided functions
- Document required sourced dependencies (e.g., `# Requires: lib/utils.sh sourced first`)

### Function Naming

- `cmd_<name>()` — command handlers, in `lib/cmd_<name>.sh`
- `_prefixed()` — internal helpers (underscore prefix)
- `descriptive_name()` — public library functions

### Error Handling

- `fail "msg"` — fatal, exits 1 to stderr
- `warn "msg"` — non-fatal, continues
- `log "msg"` — info with `[strut]` prefix
- `ok "msg"` — success with checkmark
- Never bare `|| return 1` without a message

### Configuration

- Never hardcode org names, registry types, branch names, or service names
- All config flows through `lib/config.sh` → `strut.conf`
- Per-stack config: `services.conf`, `required_vars`, `volume.conf`, `repos.conf`

### Compose & SSH

- Always use `resolve_compose_cmd` — never build compose commands manually
- Always use `build_ssh_opts` for SSH option construction
- Always use `validate_env_file` before accessing env vars

### Dry-Run

- Wrap destructive operations with `run_cmd` or `run_cmd_eval`
- Check `DRY_RUN=true` for early exit with execution plan

### Tests

- File naming: `tests/test_<module>.bats`
- Use `TEST_TMP` for temp dirs, clean up in `teardown()`
- Override `fail()` in tests so it doesn't exit the runner
- Property tests: 100 iterations with randomized inputs

## Adding a New Command

1. Create `lib/cmd_<name>.sh` with the handler function
2. Source it in the `strut` entrypoint
3. Add to the dispatch `case` block
4. Add to `usage()`
5. Write tests in `tests/test_<name>.bats`

## Project Structure

```
strut              CLI entrypoint
lib/               Shell library modules
  config.sh        Project config discovery
  registry.sh      Pluggable registry auth
  utils.sh         Colors, logging, helpers
  cmd_*.sh         Command handlers
  deploy.sh        Deploy orchestration
  health.sh        Dynamic health checks
  backup/          Backup implementations
  drift/           Drift detection
  keys/            Key management
  migrate/         VPS migration wizard
templates/         Scaffold templates
tests/             BATS test suite
install.sh         One-liner installer
VERSION            Semver version
```
