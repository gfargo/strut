# Migration Wizard Modules

This directory contains modular components for the strut migration wizard, extracted from the monolithic `migrate.sh` for better maintainability.

## Architecture

The migration wizard is split into focused modules:

```
lib/
├── migrate.sh              # Main orchestration (290 lines)
└── migrate/
    ├── ssh-helpers.sh      # SSH connection utilities
    ├── github-auth.sh      # GitHub authentication & repo access
    ├── setup-repo.sh       # Repository setup workflows
    ├── phase-preflight.sh  # Phase 1: Pre-flight checks
    ├── phase-setup.sh      # Phase 2: Setup strut on VPS
    ├── phase-audit.sh      # Phase 3: Audit existing setup
    ├── phase-generate.sh   # Phase 4: Generate stacks
    ├── phase-backup.sh     # Phase 5: Pre-cutover backup
    ├── phase-test.sh       # Phase 6: Test deployment
    ├── phase-cutover.sh    # Phase 7: Cutover
    └── phase-cleanup.sh    # Phase 8: Cleanup
```

## Modules

### ssh-helpers.sh

SSH connection and command execution utilities.

**Functions:**
- `build_ssh_cmd` — Build SSH command with port and key
- `ssh_exec` — Execute command on VPS via SSH
- `build_scp_cmd` — Build SCP command with port and key
- `test_ssh_connection` — Test SSH connectivity

### github-auth.sh

GitHub repository access and authentication helpers.

**Functions:**
- `test_github_repo_access` — Test if VPS can access a GitHub repo
- `generate_deploy_key` — Generate SSH deploy key on VPS
- `configure_deploy_key_ssh` — Configure SSH to use deploy key
- `clone_with_deploy_key` — Clone repo using deploy key
- `clone_with_pat` — Clone repo using Personal Access Token

### setup-repo.sh

High-level repository setup workflows combining SSH and GitHub auth.

**Functions:**
- `setup_repo_with_deploy_key` — Complete deploy key setup workflow
- `setup_repo_with_pat` — Complete PAT setup workflow
- `setup_strut_repo` — Main entry point (auto-detects URL type)

## Migration Phases

The main `migrate.sh` orchestrates 8 phases:

1. **Pre-flight Checks** (`phase-preflight.sh`) — SSH, Docker, disk space validation
2. **Setup strut** (`phase-setup.sh`) — Clone repository with authentication
3. **Audit** (`phase-audit.sh`) — Discover existing containers and configuration
4. **Generate Stacks** (`phase-generate.sh`) — Create stack definitions from audit
5. **Pre-Cutover Backup** (`phase-backup.sh`) — Backup databases before migration
6. **Test** (`phase-test.sh`) — Deploy and validate
7. **Cutover** (`phase-cutover.sh`) — Switch to strut management
8. **Cleanup** (`phase-cleanup.sh`) — Remove old containers and volumes

Each phase is a self-contained module that can be modified independently.

## Testing

```bash
# Syntax check all modules
bash -n lib/migrate/ssh-helpers.sh
bash -n lib/migrate/github-auth.sh
bash -n lib/migrate/setup-repo.sh
bash -n lib/migrate.sh

# Run full wizard
strut migrate <vps-host> <vps-user> <ssh-port> <ssh-key>
```
