# STACK_NAME_PLACEHOLDER (forgejo recipe)

[Forgejo](https://forgejo.org/) — Gitea's community-driven fork. Feature-compatible
with Gitea, hosted by Codeberg. Same UI/API surface, community governance model.

Prefer this over the `gitea` recipe if you want independent-community-governed
software; use `gitea` for the original.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set TZ (and optionally ROOT_URL for external HTTPS)
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:3000`. Complete first-run setup to create the admin
account and pick a database backend (SQLite is fine to start).

## Git over SSH

The container exposes SSH on host port `2222`. Clone with:

```bash
git clone ssh://git@<vps-ip>:2222/<user>/<repo>.git
```

## HTTPS

```bash
strut STACK_NAME_PLACEHOLDER domain git.example.com admin@example.com --env prod
```
