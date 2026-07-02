# STACK_NAME_PLACEHOLDER (paperless-ngx recipe)

[Paperless-ngx](https://docs.paperless-ngx.com/) — a self-hosted document
management system that transforms your paper documents into a searchable
online archive. Handles OCR, full-text search, tagging, and auto-import.

Five services: webserver, postgres, redis, gotenberg (PDF conversion),
and tika (metadata extraction). Postgres backups configured nightly.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set PAPERLESS_SECRET_KEY (openssl rand -hex 32),
# POSTGRES_PASSWORD, and admin credentials
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:8000`. Login with `PAPERLESS_ADMIN_USER` /
`PAPERLESS_ADMIN_PASSWORD`.

## Auto-import

Drop PDFs, images, or Office docs into the `CONSUME_PATH` directory (default
`./consume/`). Paperless watches the folder, OCRs each file, and files it
under its predicted tags.

## Backups

The `backup.conf` sets up a nightly Postgres backup. Also back up the
`paperless_media` volume separately — that's where your document files live.

## HTTPS

```bash
strut STACK_NAME_PLACEHOLDER domain paperless.example.com admin@example.com --env prod
```
