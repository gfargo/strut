# STACK_NAME_PLACEHOLDER (valheim recipe)

[Valheim](https://www.valheimgame.com/) dedicated server using the community
`lloesche/valheim-server` image.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set SERVER_NAME, WORLD_NAME, and SERVER_PASS
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Server listens on UDP ports 2456–2458. Open these ports in your VPS firewall or
security group before inviting players.

`SERVER_PASS` must be at least 5 characters; set it before deploying.
World saves and config persist in the `valheim_config` volume.
