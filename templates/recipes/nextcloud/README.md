# STACK_NAME_PLACEHOLDER (nextcloud recipe)

[Nextcloud](https://nextcloud.com/) (Apache image) backed by Postgres, with a
nightly Postgres backup schedule preconfigured in `backup.conf`.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set POSTGRES_PASSWORD, admin creds, and NEXTCLOUD_TRUSTED_DOMAINS
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

App is served on port 8080. Put it behind the domain/SSL flow with
`strut STACK_NAME_PLACEHOLDER domain <domain> <email> --env prod`.
Back up the database any time with `strut STACK_NAME_PLACEHOLDER backup postgres --env prod`.
