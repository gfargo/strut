# STACK_NAME_PLACEHOLDER (static-site recipe)

Caddy serving files from `public/`, with automatic TLS via Let's Encrypt.

## Layout

```
public/       Your static files — replace index.html with the real site.
caddy/        Caddyfile — reverse proxy & TLS config.
```

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set DOMAIN and ACME_EMAIL
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Point your domain's A/AAAA record at the VPS before deploying so Caddy
can complete the ACME HTTP-01 challenge.
