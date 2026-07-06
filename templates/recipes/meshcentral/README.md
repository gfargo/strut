# STACK_NAME_PLACEHOLDER (meshcentral recipe)

[MeshCentral](https://meshcentral.com/) — a free, open-source remote monitoring
and management server. Real self-hosted alternative to TeamViewer, AnyDesk, and
ConnectWise ScreenConnect. Comes with a browser-based remote desktop.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set HOSTNAME to the public URL you'll reach the server at
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `https://<vps-ip>:8083`. Create the first admin account, then install
the agent on your remote machines.

## HTTPS

MeshCentral supports built-in Let's Encrypt when exposed on port 443, but the
simpler path is to put strut's own domain command in front:

```bash
strut STACK_NAME_PLACEHOLDER domain mesh.example.com admin@example.com --env prod
```

## Data persistence

`meshcentral_data` holds config, users, and agent info. Back this up regularly
if you have real users depending on the service.
