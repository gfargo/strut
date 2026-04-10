---
name: domain-ssl
description: Configure custom domains and SSL/TLS certificates for strut stacks. Use when setting up a domain, obtaining Let's Encrypt certificates, troubleshooting HTTPS, or managing certificate renewal.
---

# Domain & SSL Configuration

Procedures for configuring custom domains and SSL certificates on strut stacks.

## Quick Reference

```bash
# Configure domain with SSL (recommended)
strut <stack> domain <your-domain.com> <admin@example.com> --env prod

# Configure domain without SSL (HTTP only)
strut <stack> domain <your-domain.com> <admin@example.com> --skip-ssl --env prod

# Example
strut my-stack domain api.cc-hub.org admin@cc-hub.org --env prod
```

## Prerequisites

### 1. DNS A Record

Your domain must point to your VPS IP:
```
api.example.com  A  <VPS_IP>  TTL=300
```

Verify:
```bash
dig +short api.example.com
# Should return your VPS IP
```

### 2. Cloud Firewall — Ports 80 + 443

Your cloud provider's firewall must allow inbound TCP on ports 80 and 443.

**DigitalOcean:** Networking → Firewalls → Add HTTP + HTTPS inbound rules
**Infomaniak:** Open support ticket requesting ports 80/443 for your VPS IP

### 3. Stack Deployed with nginx Running

```bash
strut <stack> deploy --env prod
strut <stack> status --env prod
# Verify nginx is running
```

## What the domain Command Does

1. Validates DNS resolves to correct IP
2. Generates production-ready nginx reverse proxy config
3. Obtains Let's Encrypt certificate via certbot (webroot validation)
4. Configures HTTPS with HTTP→HTTPS redirect
5. Adds security headers (HSTS, X-Frame-Options, etc.)
6. Sets up auto-renewal cron (daily at 3 AM)

## SSL Certificate Details

- Provider: Let's Encrypt (free, trusted by all browsers)
- Validity: 90 days
- Auto-renewal: daily cron checks, renews when <30 days remain
- Method: webroot validation (no downtime)
- TLS versions: 1.2 and 1.3 only
- Strong cipher configuration included

### Test Renewal

```bash
sudo certbot renew --dry-run
```

### Check Certificate Expiry

```bash
strut <stack> exec \
  "docker compose --project-name prod exec nginx openssl s_client \
   -connect localhost:443 -servername api.example.com < /dev/null 2>/dev/null \
   | openssl x509 -noout -dates" --env prod
```

## Multiple Domains

```bash
# Run domain command for each domain
strut my-stack domain api.example.com admin@example.com --env prod
strut my-stack domain api2.example.com admin@example.com --env prod
```

Or manually add server blocks to nginx config.

## Wildcard Certificates

The automated script uses webroot validation (no wildcard support). For wildcards:
```bash
sudo certbot certonly --manual --preferred-challenges dns -d "*.example.com"
# Then copy certs to nginx volume
```

## Custom nginx Configuration

After running the domain command, customize:
```bash
nano strut/stacks/<stack>/nginx/conf.d/<stack>.conf

# Reload nginx
strut <stack> exec \
  "docker compose --project-name prod restart nginx" --env prod
```

## Post-Setup: Update External Services

After domain setup, update webhook URLs in external services:
- Twilio: `https://your-domain.com/webhook/whatsapp`
- Otter.ai: `https://your-domain.com/otter/webhook`
- Custom GPT: `https://your-domain.com`

Update CI/CD health checks:
```yaml
- name: Health Check
  run: curl -sf https://your-domain.com/health || exit 1
```

## Troubleshooting

### DNS Not Resolving
```bash
dig +short your-domain.com
# If empty, wait for DNS propagation (5-60 minutes)
# Check your DNS provider settings
```

### Port 80/443 Not Accessible
```bash
# Test from external network (not from VPS)
curl -I http://your-domain.com

# Check cloud provider firewall (most common issue)
# Check VPS firewall
sudo ufw status
# Check nginx is running
docker ps | grep nginx
```

### Certificate Obtainment Failed
```bash
sudo journalctl -u certbot

# Common causes:
# - Port 80 not accessible externally (cloud firewall)
# - DNS not pointing to correct IP
# - Rate limit (5 failures per hour per domain)
```

### HTTPS Not Working After Setup
```bash
# Check nginx logs
strut <stack> logs nginx --follow --env prod

# Check cert files exist
sudo ls -la /etc/letsencrypt/live/your-domain.com/

# Verify nginx config syntax
docker exec <nginx-container> nginx -t

# Reload nginx
strut <stack> exec \
  "docker compose --project-name prod restart nginx" --env prod
```

### SSL Labs Test
Test your configuration at: `https://www.ssllabs.com/ssltest/`

## Security Features (Auto-Configured)

The generated nginx config includes:
- HSTS (1 year, includeSubDomains)
- TLS 1.2+ only, no weak ciphers
- X-Frame-Options, X-Content-Type-Options headers
- HTTP→HTTPS redirect for all traffic
- Optimized timeouts

## Related Documentation

- `strut/scripts/configure-domain.sh` — Domain setup script
- `#vps-deployment` — Deploy stack before configuring domain
- `#stack-validation` — Validate nginx config in stack
- `#vps-debugging` — Debug nginx issues
