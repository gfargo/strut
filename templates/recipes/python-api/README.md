# STACK_NAME_PLACEHOLDER (python-api recipe)

FastAPI service backed by Postgres. `GET /health` runs `SELECT 1` so
`strut STACK_NAME_PLACEHOLDER health` verifies the DB connection too.

## Layout

```
app/
  Dockerfile        Python 3.12 + FastAPI + psycopg
  requirements.txt  Python deps (pin or replace as you like)
  main.py           Example app — replace with your routes
docker-compose.yml  api + postgres services
services.conf       Health-check wiring for strut
```

## Deploy

```bash
cp .env.template .prod.env
# edit .prod.env — generate a real POSTGRES_PASSWORD and matching DATABASE_URL
strut STACK_NAME_PLACEHOLDER deploy --env prod
strut STACK_NAME_PLACEHOLDER health --env prod
```

`strut STACK_NAME_PLACEHOLDER backup postgres` and
`strut STACK_NAME_PLACEHOLDER db:pull` work out of the box because
`services.conf` flags postgres as a DB service.
