# STACK_NAME_PLACEHOLDER (uptime-kuma recipe)

[Uptime Kuma](https://github.com/louislam/uptime-kuma) is a self-hosted uptime
and status monitoring tool with a clean web dashboard.

## Deploy

```bash
cp .env.template .prod.env
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

The dashboard is available on port 3001. Open the UI to create an admin account
on first launch.

Put it behind a domain with TLS using:
`strut STACK_NAME_PLACEHOLDER domain <domain> <email> --env prod`

Monitor data persists in the `uptimekuma_data` volume.
