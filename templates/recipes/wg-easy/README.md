# STACK_NAME_PLACEHOLDER (wg-easy recipe)

[WireGuard Easy](https://github.com/wg-easy/wg-easy) — the easiest way to run
a WireGuard VPN server. Ships with a web UI for peer management, QR-code
config generation, and per-peer traffic stats.

## Deploy

```bash
# 1. Generate your bcrypt password hash
docker run --rm ghcr.io/wg-easy/wg-easy wgpw 'YourStrongPassword'

# 2. Configure the env
cp .env.template .prod.env
# Set WG_HOST to your public IP/DNS and PASSWORD_HASH to the hash above.
# NOTE: every literal $ in the hash must be doubled ($$) in the env file
# (docker-compose interpolation).
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:51821`. VPN endpoint (UDP): `<WG_HOST>:51820`.

## Firewall

Open UDP `51820` on your VPS firewall/security group. Keep `51821` (the web UI)
behind a reverse proxy with basic auth or on a Tailscale-only interface — it's
not designed to be publicly exposed.
