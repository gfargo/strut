# Configuration

strut is configured through `strut.conf` at your project root, plus per-environment `.env` files.

---

## strut.conf

Place at the root of your project directory. strut discovers it by walking up from the current directory.

```ini
# ── Container Registry ──────────────────────────
REGISTRY_TYPE=ghcr          # ghcr | dockerhub | ecr | none
DEFAULT_ORG=my-org
DEFAULT_BRANCH=main

# ── Reverse Proxy ───────────────────────────────
REVERSE_PROXY=nginx         # nginx | caddy

# ── Deploy ──────────────────────────────────────
DEPLOY_MODE=standard        # standard | blue-green
PRE_DEPLOY_VALIDATE=true
PRE_DEPLOY_HOOKS=true

# ── SSH Host Key Checking (v0.31.0+) ───────────
# Controls StrictHostKeyChecking for all strut SSH connections.
# Values: accept-new (default, TOFU), yes (strict), no (insecure legacy)
STRUT_SSH_HOST_KEY_CHECK=accept-new

# ── Branding ────────────────────────────────────
BANNER_TEXT=strut
```

### `[hosts]` Section

Defines the VPS hosts strut manages:

```ini
[hosts]
compass = ubuntu@10.0.0.1:22 ~/.ssh/compass_key
harbor  = deploy@10.0.0.2:22 ~/.ssh/harbor_key deploy_dir=/opt/stacks
watch   = ubuntu@10.0.0.3
```

**Format:** `<alias> = [user@]host[:port] [ssh_key_path] [deploy_dir=/path]`

| Field | Default | Description |
|-------|---------|-------------|
| `user` | `ubuntu` | SSH username |
| `host` | (required) | Hostname or IP |
| `port` | `22` | SSH port |
| `ssh_key_path` | (none) | Path to private SSH key |
| `deploy_dir` | `/home/<user>/strut` | Remote deploy directory (v0.31.0+) |

### `[stacks]` Section

Maps stacks to their target host:

```ini
[stacks]
my-app = compass
redis  = harbor
buoy   = watch
```

---

## Environment Variables

### SSH Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `STRUT_SSH_HOST_KEY_CHECK` | `accept-new` | SSH StrictHostKeyChecking mode (`accept-new`, `yes`, `no`) |
| `STRUT_SSH_NO_MUX` | `0` | Set to `1` to disable SSH connection multiplexing |
| `STRUT_SSH_CONTROL_DIR` | `/tmp` | Directory for SSH multiplexing control sockets |

### Project Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `STRUT_PROJECT` | (auto-detected) | Override project root (useful for paths with spaces) |
| `STRUT_NO_UPDATE_CHECK` | `0` | Set to `1` to suppress version update hints |
| `STRUT_NO_TUI` | `0` | Set to `1` to disable interactive TUI |
| `STRUT_YES` | `0` | Set to `1` to auto-approve all confirmation prompts |

### Per-Environment `.env` Files

Each environment has a `.env` file at the project root:

```
.prod.env       # Production
.staging.env    # Staging
.dev.env        # Development
```

These contain `KEY=VALUE` pairs (one per line). Supported syntax:

```dotenv
# Comments
PLAIN_KEY=value
QUOTED="value with spaces"
SINGLE_QUOTED='literal $value'
export PREFIXED=also_works
EMPTY=
```

**Important (v0.31.0+):** Shell expansion (`$VAR`, `$(cmd)`, backticks) is NOT supported in env files. Values are read literally. Use explicit values instead.

---

## Topology Precedence

When strut resolves connection info (VPS_HOST, VPS_USER, etc.), the precedence is:

1. **`--host <alias>`** CLI flag (highest priority)
2. **`[stacks]` mapping** in strut.conf
3. **Environment file** values (`.prod.env`)
4. **Defaults** (ubuntu, port 22, /home/ubuntu/strut)

---

## Related

- [Secrets Management](https://github.com/gfargo/strut/wiki/Secrets-Management) — env file hydration and providers
- [Fleet Status](https://github.com/gfargo/strut/wiki/Fleet-Status) — fleet-wide sync monitoring
- [GitHub Action](https://github.com/gfargo/strut/wiki/GitHub-Action) — CI/CD integration
