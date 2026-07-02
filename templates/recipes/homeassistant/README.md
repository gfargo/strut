# STACK_NAME_PLACEHOLDER (homeassistant recipe)

[Home Assistant](https://www.home-assistant.io/) — open-source home automation
platform focused on privacy and local control. Ties together 3,000+ smart devices
and services under one UI.

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — set your TZ
strut STACK_NAME_PLACEHOLDER deploy --env prod
```

Web UI: `http://<vps-ip>:8123`. Complete first-run onboarding.

## About networking

By default this recipe uses a bridge network (port 8123 exposed). For device
discovery (mDNS, Zigbee dongles, Zeroconf) you'll typically want `network_mode:
host` — see the commented note in `docker-compose.yml`. Enable it if you're
deploying to a home server rather than a pure VPS.
