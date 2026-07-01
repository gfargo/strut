# STACK_NAME_PLACEHOLDER (vaultwarden recipe)

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) is a lightweight,
self-hosted Bitwarden-compatible password manager server.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — generate ADMIN_TOKEN with: openssl rand -base64 48
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

The web vault is served on port 80. Put it behind TLS (required by Bitwarden
clients) with:
`strut STACK_NAME_PLACEHOLDER domain <domain> <email> --env prod`

The admin panel is available at `/admin`. Set `SIGNUPS_ALLOWED=false` after
creating your account to prevent unauthorized registrations.
All vault data persists in the `vw_data` volume.
