# STACK_NAME_PLACEHOLDER (pihole recipe)

Network-wide ad blocking + DNS via [Pi-hole](https://pi-hole.net/) (v6).

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set PIHOLE_PASSWORD and TZ
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Admin dashboard: `http://<vps-ip>/admin/`. Point your router's or devices' DNS at
the VPS IP to filter traffic. Ensure port 53 isn't already bound by a local resolver.
