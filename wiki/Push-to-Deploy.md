# Push-to-Deploy

Automatically deploy when you push to git — no manual `strut release` needed.

## Overview

strut supports two auto-deploy modes:

| Mode | How it works | When to use |
|------|-------------|-------------|
| **poll** | Fetches origin on an interval, deploys when new commits land | Behind firewalls, no inbound ports |
| **serve** | HTTP endpoint receives GitHub/GitLab webhooks | VPS has a public IP, instant deploys |

Both modes detect which stacks changed and only release the affected ones.

---

## Poll Mode (Recommended Start)

The simplest setup — no inbound ports, no webhook configuration. strut checks for new commits on a timer.

```bash
strut webhook poll                         # check every 60s, deploy all stacks
strut webhook poll --interval 30           # check every 30s
strut webhook poll --stack my-app          # only deploy my-app
strut webhook poll --branch staging        # track a different branch
strut webhook poll --once                  # single check (for cron)
```

### How It Works

1. `git fetch origin <branch>` every N seconds
2. Compares `origin/<branch>` SHA against the last deployed SHA (stored in `.webhook-last-sha`)
3. If new commits exist, diffs the file list to determine which `stacks/` changed
4. Runs `strut <stack> release --env prod` for each affected stack
5. Records the new SHA

### Persistent Setup (systemd)

```bash
strut webhook install --mode poll --interval 60
# prints a systemd unit — save it and enable:
sudo tee /etc/systemd/system/strut-webhook.service < <(strut webhook install --mode poll)
sudo systemctl daemon-reload
sudo systemctl enable --now strut-webhook
```

Check status:
```bash
sudo systemctl status strut-webhook
sudo journalctl -u strut-webhook -f
```

### Cron Alternative

For lighter setups, run a single poll per minute via cron:

```bash
* * * * * cd /home/ubuntu/strut && ./strut webhook poll --once >> /var/log/strut-webhook.log 2>&1
```

---

## Serve Mode (Instant Deploys)

An HTTP endpoint that receives push events from GitHub/GitLab. Deploys happen within seconds of a push.

```bash
strut webhook serve --port 9876 --secret "$WEBHOOK_SECRET"
```

### Prerequisites

- `socat` installed (`apt install socat`)
- Port accessible from GitHub (or fronted by your nginx/Caddy reverse proxy)
- A webhook secret for HMAC validation

### GitHub Configuration

1. Go to repo **Settings → Webhooks → Add webhook**
2. Payload URL: `http://<your-vps-ip>:9876/webhook`
3. Content type: `application/json`
4. Secret: same value as `--secret`
5. Events: select **Just the push event**

### GitLab Configuration

1. Go to project **Settings → Webhooks**
2. URL: `http://<your-vps-ip>:9876/webhook`
3. Secret token: same value as `--secret`
4. Trigger: **Push events**

### Security

- **HMAC-SHA256 validation** — every request is verified against the shared secret. Forged payloads receive `401 Unauthorized`.
- **Branch filtering** — only pushes to the configured branch trigger deploys.
- **Bind to localhost** — front with nginx/Caddy for public access with TLS.

### Persistent Setup

```bash
# Create secret file
echo "WEBHOOK_SECRET=your-random-secret-here" > /home/ubuntu/strut/.webhook.env
chmod 600 /home/ubuntu/strut/.webhook.env

# Generate and install systemd unit
strut webhook install --mode serve --port 9876 | sudo tee /etc/systemd/system/strut-webhook.service
sudo systemctl daemon-reload
sudo systemctl enable --now strut-webhook
```

### Behind a Reverse Proxy

If you already run nginx or Caddy for your stacks, proxy the webhook through it:

**nginx:**
```nginx
location /webhook {
    proxy_pass http://127.0.0.1:9876;
    proxy_set_header X-Hub-Signature-256 $http_x_hub_signature_256;
    proxy_set_header Content-Type $content_type;
}
```

**Caddy:**
```
your-domain.com {
    handle /webhook {
        reverse_proxy localhost:9876
    }
}
```

---

## Smart Stack Detection

Both modes only deploy stacks whose files actually changed:

```
push changes stacks/my-app/docker-compose.yml → releases my-app only
push changes stacks/redis/backup.conf         → releases redis only
push changes strut.conf                       → releases nothing (no stack-specific change)
push changes stacks/my-app/ + stacks/redis/   → releases both
```

Force-deploy a specific stack regardless of changes:

```bash
strut webhook poll --stack my-app --once
```

---

## Configuration

### strut.conf (optional)

```ini
# Default branch for webhook tracking
DEFAULT_BRANCH=main
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEFAULT_BRANCH` | `main` | Branch to track for deploys |
| `WEBHOOK_SECRET` | (none) | HMAC secret for serve mode |
| `GH_PAT` | (none) | GitHub PAT for private repo fetch |

---

## Monitoring

Check the webhook state:

```bash
cat .webhook-last-sha              # last deployed commit
strut fleet status                 # verify hosts are in sync
sudo journalctl -u strut-webhook   # systemd logs
```

---

## Comparison: Poll vs Serve vs GitHub Action

| | Poll | Serve | GitHub Action |
|---|---|---|---|
| Setup complexity | Low (no network config) | Medium (port + secret) | Medium (secrets + workflow) |
| Deploy latency | Up to `--interval` seconds | Instant (~2s) | 30-90s (runner spin-up) |
| Works behind firewall | ✓ | ✗ (needs inbound port) | ✓ |
| External dependency | None | socat | GitHub-hosted runner |
| Resource usage | Minimal (one fetch/min) | Minimal (idle socket) | None on VPS |

**Recommendation:** Start with poll mode. Switch to serve when you want instant deploys and have a public-facing port.

---

## Related

- [Fleet Status](https://github.com/gfargo/strut/wiki/Fleet-Status) — verify hosts are in sync after auto-deploys
- [GitHub Action](https://github.com/gfargo/strut/wiki/GitHub-Action) — alternative: deploy from CI instead of VPS
- [CLI Reference](https://github.com/gfargo/strut/wiki/CLI-Reference) — full `webhook` command docs
