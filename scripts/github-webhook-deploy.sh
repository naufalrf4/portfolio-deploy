#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${PORTFOLIO_WEBHOOK_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOCK_FILE="${PORTFOLIO_WEBHOOK_LOCK_FILE:-/var/lib/portfolio-webhook/deploy.lock}"
STATE_FILE="${PORTFOLIO_WEBHOOK_STATE_FILE:-/var/lib/portfolio-webhook/last-successful-deploy}"
STATE_DIR="${PORTFOLIO_WEBHOOK_STATE_DIR:-$(dirname "$STATE_FILE")}"
LOG_FILE="${PORTFOLIO_WEBHOOK_LOG_FILE:-/var/log/portfolio-webhook/deploy.log}"
BRANCH="${PORTFOLIO_WEBHOOK_BRANCH:-main}"
DELIVERY_ID="${1:-manual}"
export TZ="${TZ:-Asia/Jakarta}"

mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$LOG_FILE")"

release_failed_delivery() {
  local status="$1"
  if [ "$status" -ne 0 ] && [ "$DELIVERY_ID" != manual ]; then
    local marker
    marker="$(printf '%s' "$DELIVERY_ID" | sha256sum | cut -d' ' -f1)"
    rm -f "$STATE_DIR/deliveries/$marker"
  fi
}
trap 'release_failed_delivery "$?"' EXIT

exec 9>"$LOCK_FILE"
flock 9

full_deploy() {
  printf '%s\n' __FULL__
}

classify_changes() {
  local old_sha="$1" new_sha="$2" changed key
  if [ -z "$old_sha" ] || ! git -C "$ROOT_DIR" cat-file -e "$old_sha^{commit}" 2>/dev/null; then
    full_deploy
    return
  fi
  if [ "$old_sha" = "$new_sha" ]; then
    printf '%s\n' __SKIP__
    return
  fi
  if ! changed="$(git -C "$ROOT_DIR" diff --name-only "$old_sha" "$new_sha")"; then
    full_deploy
    return
  fi
  if printf '%s\n' "$changed" | grep -qE '^(docker-compose\.yml|scripts/(docker-prod-(up|migrate)\.sh|validate-image-pins\.sh|github-webhook-deploy\.sh|github_webhook_server\.py))$'; then
    full_deploy
    return
  fi

  local targets=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ "$file" = production-images.env ] || continue
    while IFS= read -r key; do
      case "$key" in
        ADMIN_IMAGE|ADMIN_MIGRATOR_IMAGE) targets+=(admin admin-cron notification-dispatch) ;;
        RAG_IMAGE) targets+=(rag) ;;
        PRESENCE_IMAGE) targets+=(live-presence) ;;
      esac
    done < <(git -C "$ROOT_DIR" diff "$old_sha" "$new_sha" -- production-images.env | sed -nE 's/^[+-]([A-Z_]+)=.*/\1/p' | sort -u)
  done <<<"$changed"

  if [ "${#targets[@]}" -eq 0 ]; then
    printf '%s\n' __NONE__
    return
  fi
  printf '%s\n' "${targets[@]}" | awk '!seen[$0]++'
}

{
  printf '\n[%s] deploy start\n' "$(date -Iseconds)"
  printf 'delivery=%s\n' "$DELIVERY_ID"
  printf 'target_branch=%s\n' "$BRANCH"

  LAST_SUCCESS_SHA="$(cat "$STATE_FILE" 2>/dev/null || true)"
  if [[ ! "$LAST_SUCCESS_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    LAST_SUCCESS_SHA=""
  fi

  git -C "$ROOT_DIR" fetch origin
  git -C "$ROOT_DIR" checkout "$BRANCH"
  git -C "$ROOT_DIR" pull --ff-only origin "$BRANCH"
  NEW_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  mapfile -t DEPLOY_TARGETS < <(classify_changes "$LAST_SUCCESS_SHA" "$NEW_SHA")

  case "${DEPLOY_TARGETS[0]:-}" in
    __SKIP__)
      printf 'no changes since last successful deploy (%s); skipping\n' "$NEW_SHA"
      ;;
    __NONE__)
      printf 'non-deployment files changed; skipping service rollout\n'
      ;;
    __FULL__)
      printf 'deployment configuration changed (or first deploy); full rollout\n'
      bash "$ROOT_DIR/scripts/docker-prod-up.sh"
      ;;
    *)
      printf 'image pins changed; targets: %s\n' "${DEPLOY_TARGETS[*]}"
      bash "$ROOT_DIR/scripts/docker-prod-up.sh" "${DEPLOY_TARGETS[@]}"
      ;;
  esac

  STATE_TMP="${STATE_FILE}.tmp.$$"
  printf '%s\n' "$NEW_SHA" >"$STATE_TMP"
  mv "$STATE_TMP" "$STATE_FILE"
  printf 'recorded successful revision=%s\n' "$NEW_SHA"
  printf '[%s] deploy success\n' "$(date -Iseconds)"
} >>"$LOG_FILE" 2>&1
