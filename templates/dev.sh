#!/usr/bin/env bash
# ==================================================
# dev.sh — Local development helper
# ==================================================
# Mirrors common dev.sh conventions for service repos.
# All Python commands run inside Docker (never bare python).
#
# Usage:
#   ./dev.sh up              Start dev stack (Redis, Postgres)
#   ./dev.sh down            Stop dev stack
#   ./dev.sh rebuild         Rebuild Docker image after code changes
#   ./dev.sh test            Run full test suite
#   ./dev.sh test:quick      Quick smoke test
#   ./dev.sh python <args>   Run Python in container
#   ./dev.sh shell           Drop into container shell
#   ./dev.sh logs            Tail app logs
#   ./dev.sh lint            Run flake8
#   ./dev.sh format          Run black

set -e

COMPOSE="docker compose -f docker-compose.dev.yml"
SERVICE_NAME="${SERVICE_NAME:-app}" # override if needed

case "${1:-}" in
  up)
    $COMPOSE up -d
    echo "Dev stack ready. Redis: localhost:6379, Postgres: localhost:5432"
    ;;

  down)
    $COMPOSE down
    ;;

  rebuild)
    docker compose build --no-cache "$SERVICE_NAME"
    echo "Rebuild complete."
    ;;

  test)
    docker compose run --rm "$SERVICE_NAME" pytest tests/ -v "${@:2}"
    ;;

  test:quick)
    docker compose run --rm "$SERVICE_NAME" pytest tests/ -x -q "${@:2}"
    ;;

  python)
    docker compose run --rm "$SERVICE_NAME" python "${@:2}"
    ;;

  shell)
    docker compose run --rm "$SERVICE_NAME" bash
    ;;

  logs)
    $COMPOSE logs -f "${@:2}"
    ;;

  lint)
    docker compose run --rm "$SERVICE_NAME" python -m flake8 src/
    ;;

  format)
    docker compose run --rm "$SERVICE_NAME" python -m black src/
    ;;

  "")
    echo "Usage: ./dev.sh <command>"
    echo ""
    echo "Commands: up, down, rebuild, test, test:quick, python, shell, logs, lint, format"
    ;;

  *)
    echo "Unknown command: $1"
    exit 1
    ;;
esac
