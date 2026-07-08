# Auto-SSL

strut automatically provisions Let's Encrypt certificates for domains detected in your stack after a successful deploy.

## How It Works

After `strut release` completes and health checks pass:

1. **Detect domains** from compose labels or env vars
2. **Check DNS** — verify the domain resolves to the VPS IP
3. **Check cert** — skip if a valid cert exists (>30 days remaining)
4. **Provision** — run certbot to obtain the certificate
5. **Skip gracefully** — if DNS isn't ready or certbot fails, warn but don't fail the deploy

## Configuring Domains

### Option 1: Compose Labels (Recommended)

```yaml
services:
  web:
    image: my-app:latest
    labels:
      strut.domain: "api.example.com"
```

For multiple domains, add the label to multiple services or use comma-separation in env.

### Option 2: Environment Variables

```dotenv
# .prod.env
DOMAIN=api.example.com
SSL_EMAIL=admin@example.com
```

Or multiple domains:
```dotenv
DOMAINS=api.example.com,app.example.com
SSL_EMAIL=admin@example.com
```

The `VIRTUAL_HOST` variable (nginx-proxy convention) is also detected.

## Configuration

### strut.conf

```ini
AUTO_SSL=true                    # default: true
SSL_EMAIL=admin@example.com      # required for Let's Encrypt registration
```

### Disabling Per-Stack

```dotenv
# .prod.env
AUTO_SSL=false    # skip auto-SSL for this stack (e.g. internal-only services)
```

### Prerequisites on VPS

- `certbot` installed (`apt install certbot`)
- Port 80 accessible from the internet (for ACME challenge)
- DNS A record pointing to the VPS IP

## Detection Priority

Domains are collected from (in order):
1. Compose service labels: `strut.domain`
2. Env var: `DOMAIN`
3. Env var: `DOMAINS` (comma-separated)
4. Env var: `VIRTUAL_HOST` (comma-separated, nginx-proxy compat)

Duplicates are removed automatically.

## Behavior

| Condition | Result |
|-----------|--------|
| Valid cert exists (>30 days) | Skip silently |
| Cert expiring (<30 days) | Re-provision |
| No cert exists | Provision new |
| DNS doesn't resolve to VPS | Warn, skip (non-blocking) |
| certbot fails | Warn, skip (deploy still succeeds) |
| `AUTO_SSL=false` | Skip entirely |
| `SSL_EMAIL` not set | Skip entirely |

Auto-SSL **never fails a deploy**. It's advisory — if cert provisioning fails, the deploy still completes and you can fix SSL manually with `strut <stack> domain`.

## Manual Override

The existing `strut <stack> domain` command continues to work as an explicit override for cases where auto-detection doesn't apply (wildcard certs, custom nginx config, etc.):

```bash
strut my-stack domain api.example.com admin@example.com --env prod
```

## Cert Renewal

Let's Encrypt certs expire every 90 days. Renewal is handled separately from auto-provision:

- certbot installs a system cron/timer by default (`certbot renew`)
- strut's `cert:renew` command can also trigger renewal manually
- Auto-SSL re-provisions expiring certs on deploy (catches any that slipped through)

## Troubleshooting

### "does not resolve to VPS IP"

The domain's DNS A record doesn't point to this server. Either:
- DNS hasn't propagated yet (wait 5-60 minutes)
- Wrong IP in DNS settings
- Cloudflare proxy enabled (use "DNS only" mode for initial provisioning)

### "certbot failed"

```bash
# Check port 80 is open
curl -I http://your-domain.com

# Check certbot is installed
ssh ubuntu@<vps> "certbot --version"

# Check cloud firewall allows port 80 inbound
# (most common issue — DigitalOcean, Hetzner, etc. block by default)

# Manual provision for debugging
ssh ubuntu@<vps> "certbot certonly --standalone -d your-domain.com --email admin@example.com"
```

### "auto-ssl skipped silently"

Check that:
1. `SSL_EMAIL` is set in strut.conf or your env file
2. `AUTO_SSL` is not set to `false`
3. At least one domain is configured (label or env var)

## Related

- [Push-to-Deploy](https://github.com/gfargo/strut/wiki/Push-to-Deploy) — auto-SSL runs after webhook-triggered deploys too
- [Configuration](https://github.com/gfargo/strut/wiki/Configuration) — `AUTO_SSL` and `SSL_EMAIL` reference
- [CLI Reference](https://github.com/gfargo/strut/wiki/CLI-Reference) — `strut domain` and `cert:*` commands
