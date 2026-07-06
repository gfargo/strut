# STACK_NAME_PLACEHOLDER (palworld recipe)

[Palworld](https://www.pocketpair.jp/palworld) dedicated server via
[thijsvanloef/palworld-server-docker](https://github.com/thijsvanloef/palworld-server-docker) —
the community-standard image.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set SERVER_NAME, SERVER_PASSWORD, ADMIN_PASSWORD
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Connect: launch Palworld, Join Multiplayer Game → enter `<vps-ip>:8211`
with the password from `.prod.env`.

## Ports

- UDP **8211** — game port
- UDP **27015** — Steam query port (needed for public listing)

Both must be open on your VPS firewall.

## Memory

Palworld needs **at least 8 GB RAM** for a stable 4-player world, more for
larger groups. Small VPS instances will thrash.

## RCON

The admin password enables RCON console commands. See the upstream README
for the full command list.
