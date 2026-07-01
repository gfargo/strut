# STACK_NAME_PLACEHOLDER (minecraft recipe)

Minecraft Java Edition server via [itzg/minecraft-server](https://github.com/itzg/docker-minecraft-server).

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — EULA must be TRUE, tune MEMORY/VERSION
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Connect a client to `<vps-ip>:25565`. World data persists in the `mc_data` volume.
