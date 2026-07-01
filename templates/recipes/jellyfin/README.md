# STACK_NAME_PLACEHOLDER (jellyfin recipe)

[Jellyfin](https://jellyfin.org/) is a free, open-source media server —
a zero-license-key alternative to Plex.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set your timezone
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

The web UI is available on port 8096. Complete the first-run wizard at
`http://<your-vps>:8096` to create an admin account and add media libraries.

Media lives in the `jellyfin_media` named volume. To serve files from a host
directory instead, replace the `jellyfin_media:/media` volume entry in
`docker-compose.yml` with a bind mount (e.g. `/mnt/media:/media`).

Put the server behind TLS with:
`strut STACK_NAME_PLACEHOLDER domain <domain> <email> --env prod`
