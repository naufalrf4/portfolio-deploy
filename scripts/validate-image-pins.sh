#!/usr/bin/env bash
# Validate the immutable Git SHA image tags used by this deployment candidate.
set -euo pipefail

IMAGE_ENV_FILE="${1:?usage: validate-image-pins.sh IMAGE_ENV_FILE}"
required=(ADMIN_IMAGE ADMIN_MIGRATOR_IMAGE RAG_IMAGE PRESENCE_IMAGE)

validate_pin() {
  local name="$1" value
  value="$(awk -F= -v key="$name" '$1 == key { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$IMAGE_ENV_FILE")" || {
    echo "missing image pin: $name in $IMAGE_ENV_FILE" >&2
    return 1
  }
  if [[ ! "$value" =~ ^[^[:space:]@]+:[[:xdigit:]]{40}$ ]]; then
    echo "image pin must end in a 40-character Git SHA tag: $name" >&2
    return 1
  fi
}

for name in "${required[@]}"; do
  validate_pin "$name"
done
