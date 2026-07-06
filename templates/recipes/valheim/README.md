# STACK_NAME_PLACEHOLDER (valheim recipe)

[Valheim](https://www.valheimgame.com/) dedicated server via
[lloesche/valheim-server](https://github.com/lloesche/valheim-server-docker) —
the community-standard Docker image with auto-updates and rolling backups.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set SERVER_NAME, SERVER_PASS (≥5 chars), WORLD_NAME
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Connect: launch Valheim, Join Game, Join by IP → `<vps-ip>:2456`.

## Ports

UDP 2456 (game) and 2457 (query/steam) must be open on your VPS firewall.
Valheim is UDP-only — no TCP required.

## World data

World saves live in the `valheim_config` volume. Back up with:

```bash
strut STACK_NAME_PLACEHOLDER exec 'docker cp STACK_NAME_PLACEHOLDER-valheim:/config/worlds_local ./worlds-backup' --env prod
```

Or configure the image's built-in backup rotation via env vars — see the
lloesche/valheim-server README.

## Memory

Valheim needs **at least 4 GB RAM**. On smaller VPS instances, add swap or
use a larger droplet.
