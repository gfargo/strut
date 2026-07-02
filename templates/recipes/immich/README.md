# STACK_NAME_PLACEHOLDER (immich recipe)

[Immich](https://immich.app/) — high-performance self-hosted photo and video
backup solution, with a mobile app for iOS and Android that auto-uploads from
your phone. A real Google Photos / iCloud Photos alternative.

Runs four services: server (API + web UI), machine-learning (CLIP embeddings,
face recognition), postgres (with pgvecto-rs for vector search), and redis.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set DB_PASSWORD and UPLOAD_LOCATION (point at a big disk!)
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:2283`. Complete first-run setup to create the admin user.

## Mobile app

Download from the App Store / Play Store, then point it at `http://<vps-ip>:2283`
(HTTPS strongly recommended in production).

## Backups

`backup.conf` sets up a nightly Postgres backup. Also back up your `UPLOAD_LOCATION`
directory separately (rsync to another disk, or use `strut backup` custom hooks).

## HTTPS

```bash
strut STACK_NAME_PLACEHOLDER domain photos.example.com admin@example.com --env prod
```
