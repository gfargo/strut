# STACK_NAME_PLACEHOLDER (jellyfin recipe)

[Jellyfin](https://jellyfin.org/) — self-hosted media server, an FOSS alternative
to Plex. Streams movies, TV, and music to your devices from your own server.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set TZ and MEDIA_PATH to your library
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:8096`. Complete first-run setup to add libraries.

## Add a domain

```bash
strut STACK_NAME_PLACEHOLDER domain jellyfin.example.com admin@example.com --env prod
```
