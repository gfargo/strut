# STACK_NAME_PLACEHOLDER (factorio recipe)

[Factorio](https://www.factorio.com/) headless multiplayer server via the
official [factoriotools/factorio](https://hub.docker.com/r/factoriotools/factorio-docker)
image.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set GAME_PASSWORD
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Connect: launch Factorio, Multiplayer → Connect to address → `<vps-ip>:34197`
with the password from `.prod.env`.

## Port

UDP 34197 must be open on your VPS firewall. Factorio is UDP-only.

## Saves & mods

Saves live under `/factorio/saves` in the `factorio_data` volume. Mods go
under `/factorio/mods`. Copy files in with `docker cp` or `strut exec`.

## Config

Advanced settings (game-settings.json, server-settings.json, etc.) can be
placed under `/factorio/config` in the volume. See the upstream README for
the full config surface.
