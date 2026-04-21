# STACK_NAME_PLACEHOLDER (next-postgres recipe)

Next.js app + Postgres + Caddy reverse proxy with auto TLS.

## Layout

```
app/               Next.js source (stub — replace with your app)
docker-compose.yml web + postgres + proxy
caddy/Caddyfile    Terminates TLS, proxies to web:3000
services.conf      Health-check wiring
```

## Wire up

1. Point `DOMAIN`'s A/AAAA records at the VPS.
2. Set `output: 'standalone'` in `next.config.js` and add a
   `GET /api/health` route returning 200.
3. Fill `.prod.env`:
   ```bash
   cp .env.template .prod.env
   # edit DOMAIN, ACME_EMAIL, POSTGRES_PASSWORD, DATABASE_URL, NEXTAUTH_SECRET
   ```
4. Deploy:
   ```bash
   strut STACK_NAME_PLACEHOLDER deploy --env prod
   strut STACK_NAME_PLACEHOLDER health --env prod
   ```
