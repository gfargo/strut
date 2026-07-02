# STACK_NAME_PLACEHOLDER (audiobookshelf recipe)

[Audiobookshelf](https://www.audiobookshelf.org/) — a self-hosted server for
audiobooks and podcasts, with iOS and Android apps. A real self-hosted
alternative to Audible for your own audiobook library.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — point AUDIOBOOKS_PATH and PODCASTS_PATH at your libraries
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:13378`. Complete first-run setup to create the admin
account, add your libraries, and configure clients.

## HTTPS

```bash
strut STACK_NAME_PLACEHOLDER domain audiobooks.example.com admin@example.com --env prod
```
