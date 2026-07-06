# STACK_NAME_PLACEHOLDER (ntfy recipe)

[ntfy](https://ntfy.sh/) — a simple pub/sub notification service that lets you
send push notifications to your phone or desktop with a single HTTP request.
No accounts required (for the public server); self-hosted for full control.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set BASE_URL to the public URL you'll reach the server at
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI + API: `http://<vps-ip>:8082`. Install the ntfy iOS/Android app and
point it at your `BASE_URL`.

## Send a notification

```bash
curl -d "Deploy complete" http://<vps-ip>:8082/mytopic
```

Wire it into strut lifecycle hooks (see [[Lifecycle Hooks]]) for deploy-done
alerts, backup-done, health-fail, etc.

## HTTPS is strongly recommended

Set `BASE_URL=https://…` and put ntfy behind a real cert. Some mobile
platforms refuse HTTP webhooks.

```bash
strut STACK_NAME_PLACEHOLDER domain ntfy.example.com admin@example.com --env prod
```
