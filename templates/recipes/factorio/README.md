# STACK_NAME_PLACEHOLDER (factorio recipe)

[Factorio](https://www.factorio.com/) headless game server using the official
`factoriotools/factorio` image.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — adjust port or save name if needed
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Server listens on UDP port 34197. Open this port in your VPS firewall.
Game data and saves persist in the `factorio_data` volume.
The `stable` image tag is used by default; pin to a specific version in
`docker-compose.yml` for reproducible deployments.
