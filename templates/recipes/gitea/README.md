# STACK_NAME_PLACEHOLDER (gitea recipe)

[Gitea](https://about.gitea.com/) — a lightweight, self-hosted Git service that
looks and feels a lot like GitHub. Excellent for personal projects, homelabs,
and small teams that want to keep code under their own control.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set TZ (and optionally ROOT_URL for external HTTPS)
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:3000`. Complete first-run setup to create the admin account
and pick a database backend (SQLite is fine to start; Postgres available in the wizard).

## Git over SSH

The container exposes SSH on host port `2222`. Clone with:

```bash
git clone ssh://git@<vps-ip>:2222/<user>/<repo>.git
```

## HTTPS

```bash
strut STACK_NAME_PLACEHOLDER domain git.example.com admin@example.com --env prod
```
