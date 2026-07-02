# STACK_NAME_PLACEHOLDER (ghost recipe)

[Ghost](https://ghost.org/) — professional publishing platform with built-in
newsletter and membership features. A serious self-hosted alternative to
Substack, Medium, and Beehiiv for people who want to own their audience.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set MYSQL_PASSWORD and GHOST_URL (the public HTTPS URL)
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Admin UI: `<GHOST_URL>/ghost` — complete first-run setup to create the owner
account. Frontend site is at `<GHOST_URL>/`.

## HTTPS is required

Ghost's admin panel refuses to work over plain HTTP once `GHOST_URL` is set to
an https URL. Wire up SSL before completing setup:

```bash
strut STACK_NAME_PLACEHOLDER domain blog.example.com admin@example.com --env prod
```

## Newsletters

To send newsletters via Mailgun, add these to `.prod.env` and redeploy:

```bash
mail__transport=SMTP
mail__options__service=Mailgun
mail__options__auth__user=<mailgun-user>
mail__options__auth__pass=<mailgun-password>
```
