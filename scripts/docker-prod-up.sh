#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT_TIMEOUT="${PROD_HEALTH_WAIT_TIMEOUT:-240}"
ROLLBACK_FILE="$ROOT_DIR/.docker-prod-rollback.yml"
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

# Public/Links/NGL are hosted on Cloudflare Pages. Keep their Node containers
# opt-in as VPS fallbacks; they are not part of the normal production deploy.
ALL_SERVICES=(admin admin-cron notification-dispatch rag live-presence)
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${ALL_SERVICES[@]}")
fi

compose() {
  docker compose \
    --env-file "$ENV_FILE" \
    -f "$ROOT_DIR/docker-compose.yml" \
    "$@"
}

running_image() {
  local cid
  cid="$(compose ps -q "$1" 2>/dev/null | head -1)"
  [ -n "$cid" ] || return 0
  docker inspect --format '{{.Image}}' "$cid" 2>/dev/null || true
}

declare -A PREVIOUS_IMAGE=()
for svc in "${TARGETS[@]}"; do
  PREVIOUS_IMAGE["$svc"]="$(running_image "$svc")"
done

cleanup() {
  rm -f "$ROLLBACK_FILE"
}
trap cleanup EXIT

rollback() {
  echo "deploy failed: rolling back to previously running images" >&2

  local pinned=0
  printf 'services:\n' >"$ROLLBACK_FILE"
  for svc in "${TARGETS[@]}"; do
    local image="${PREVIOUS_IMAGE[$svc]:-}"
    [ -n "$image" ] || continue
    printf '  %s:\n    image: %s\n' "$svc" "$image" >>"$ROLLBACK_FILE"
    pinned=1
  done

  if [ "$pinned" -eq 0 ]; then
    echo "no previously running images to roll back to; stopping failed services" >&2
    compose stop "${TARGETS[@]}" || true
    return 1
  fi

  if docker compose \
    --env-file "$ENV_FILE" \
    -f "$ROOT_DIR/docker-compose.yml" \
    -f "$ROLLBACK_FILE" \
    up -d --no-build --wait --wait-timeout "$WAIT_TIMEOUT" "${TARGETS[@]}"; then
    echo "rollback complete: services restored to previous images" >&2
  else
    echo "ROLLBACK DEGRADED: previous images did not become healthy either; prod needs manual attention" >&2
    compose ps >&2 || true
  fi

  return 1
}

for svc in "${TARGETS[@]}"; do
  compose pull "$svc"
done

if ! compose up -d --no-build --wait --wait-timeout "$WAIT_TIMEOUT" "${TARGETS[@]}"; then
  compose ps
  compose logs --tail 50 "${TARGETS[@]}" || true
  rollback
fi

echo "deploy healthy (pulled images): ${TARGETS[*]}"
