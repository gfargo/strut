# STACK_NAME_PLACEHOLDER (uptime-kuma recipe)

[Uptime Kuma](https://github.com/louislam/uptime-kuma) — a self-hosted, single-container
uptime monitor. Monitors HTTP, HTTPS, TCP, DNS, ping, and more, with status pages
and rich notification channels.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set your TZ
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:3001`. Complete first-run setup to create your admin account.
