# STACK_NAME_PLACEHOLDER (vaultwarden recipe)

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) — a lightweight,
Rust-based server implementation of the Bitwarden API. Compatible with all
official Bitwarden clients (mobile, desktop, browser extensions).

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set ADMIN_TOKEN and DOMAIN
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:8080`. Admin panel: `<DOMAIN>/admin` (uses ADMIN_TOKEN).

## HTTPS strongly recommended

Vaultwarden requires HTTPS for the browser-add-on WebSocket. Add a domain:

```bash
strut STACK_NAME_PLACEHOLDER domain vault.example.com admin@example.com --env prod
```
