# STACK_NAME_PLACEHOLDER (umami recipe)

[Umami](https://umami.is/) — a privacy-friendly, cookieless, GDPR-compliant
web analytics platform. Self-hosted alternative to Google Analytics.

Ships with Postgres and a nightly backup schedule.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set POSTGRES_PASSWORD and APP_SECRET (openssl rand -hex 32)
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:3100`. Default credentials on first run: `admin` /
`umami`. **Change the password immediately.** Add a website and paste the
tracking snippet into your site's `<head>`.

## HTTPS + custom domain

```bash
strut STACK_NAME_PLACEHOLDER domain analytics.example.com admin@example.com --env prod
```
