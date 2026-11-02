#!/usr/bin/env bash
# Ensure every app image in the deploy Compose file uses an immutable Git SHA tag.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${1:-$ROOT_DIR/docker-compose.yml}"
mapfile -t pins < <(grep -E '^[[:space:]]*image: ghcr\.io/naufalrf4/(portfolio-admin|portfolio-admin-migrator|portfolio-rag|portfolio-presence):' "$COMPOSE_FILE")

if ((${#pins[@]} != 5)); then
  echo "expected five pinned GHCR image references in $COMPOSE_FILE; found ${#pins[@]}" >&2
  exit 1
fi

for entry in "${pins[@]}"; do
  image="${entry#*: }"
  if [[ ! "$image" =~ ^ghcr\.io/naufalrf4/[a-z-]+:[[:xdigit:]]{40}$ ]]; then
    echo "image pin must use a full 40-character Git SHA tag: $image" >&2
    exit 1
  fi
done
