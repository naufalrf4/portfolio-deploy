#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROD_ENV_FILE:-$ROOT_DIR/.env.docker.prod}"
if [ ! -f "$ENV_FILE" ] && [ -f "$ROOT_DIR/.env" ]; then
  # Dokploy writes its Compose variables to .env in the deployed checkout.
  ENV_FILE="$ROOT_DIR/.env"
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "production env file not found: set PROD_ENV_FILE or provide .env.docker.prod" >&2
  exit 1
fi
bash "$ROOT_DIR/scripts/validate-image-pins.sh"

compose() {
  docker compose \
    --env-file "$ENV_FILE" \
    -f "$ROOT_DIR/docker-compose.yml" \
    "$@"
}

# Pull migration/bootstrap images; the migration image does not compile Next.js.
compose --profile ops pull rag-bootstrap admin-migrate

compose --profile ops run --rm rag-bootstrap

compose --profile ops run --rm admin-migrate

# Fail loudly on drift. Without this a migration that exists in git but never
# reached the database stays invisible until app code hits the missing relation
# at runtime (Postgres 42P01).
compose --profile ops run --rm admin-migrate bun run db:verify
