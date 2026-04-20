---
inclusion: fileMatch
fileMatchPattern: "lib/**/*.sh,strut,tests/**/*.bats"
---

# strut Code Conventions

## Shell Scripts (lib/*.sh)

Every lib module must:
- Start with `#!/usr/bin/env bash`
- Have a header comment block: module name, description, dependencies, provided functions
- Include `set -euo pipefail`
- Document required sourced dependencies (e.g., `# Requires: lib/utils.sh sourced first`)

## Function Naming

- Command handlers: `cmd_<name>()` in `lib/cmd_<name>.sh`
- Internal helpers: `_prefixed_name()` (underscore prefix)
- Public library functions: `descriptive_name()` (no prefix)

## Error Handling

- `fail "message"` — fatal, exits 1 to stderr
- `warn "message"` — non-fatal, continues to stdout
- `log "message"` — informational with `[strut]` prefix
- `ok "message"` — success with checkmark
- Never use bare `|| return 1` without a message

## Configuration

- All config is read from `strut.conf` via `lib/config.sh` — never hardcode org names, registry types, branch names, or service names
- Per-stack config comes from `services.conf`, `required_vars`, `volume.conf`, `repos.conf`
- Defaults are defined in `load_strut_config()` only

## SSH Commands

- Always use `build_ssh_opts` for consistent SSH option building
- Always use `validate_env_file` before accessing env vars

## Compose Commands

- Always use `resolve_compose_cmd` for consistent project naming
- Never construct compose commands manually

## Dry-Run

- Wrap destructive operations with `run_cmd` or `run_cmd_eval`
- Check `DRY_RUN=true` for early exit with execution plan display

## Tests (BATS)

- Test files: `tests/test_<module>.bats`
- Use `setup()` / `teardown()` with `TEST_TMP` for temp dirs
- Source `test_helper/common.bash` for shared helpers
- Override `fail()` in tests: `fail() { echo "$1" >&2; return 1; }`
- Property tests: 100 iterations with randomized inputs
- Static analysis tests: grep-based checks for hardcoded references
- Tests calling handlers must export `CMD_*` variables (CMD_STACK, CMD_STACK_DIR, CMD_ENV_FILE, CMD_ENV_NAME, CMD_SERVICES, CMD_JSON)
- Use `if` blocks instead of `&&` chains for conditional logic (avoids `set -e` failures)
- Support both macOS and Linux `stat` syntax in tests

## Security

- Never use `eval` with values from config files or env vars
- Use `envsubst` or pattern matching for variable expansion
- Validate all user input before passing to shell commands
- Env files must be gitignored — `strut validate` should warn if tracked
