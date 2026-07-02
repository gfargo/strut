# STACK_NAME_PLACEHOLDER (n8n recipe)

[n8n](https://n8n.io/) — fair-code, node-based workflow automation. A self-hosted
alternative to Zapier / Make.com with 400+ built-in integrations. Great for AI
agent orchestration, API-glue, and no/low-code automation.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set N8N_ENCRYPTION_KEY, N8N_HOST, admin credentials
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:5678`. Sign in with the basic-auth credentials.

## HTTPS setup

For webhooks and OAuth to work with third-party services, expose over HTTPS:

```bash
strut STACK_NAME_PLACEHOLDER domain n8n.example.com admin@example.com --env prod
```
