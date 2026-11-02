# VPS deployment

This repository contains deployment configuration only: production Compose, migration/rollout helpers, and a non-secret `production-images.env` file pinning immutable image tags. Dokploy at `cloud.nrflabs.net` owns deployment to its configured remote server. No extra DNS name or custom webhook receiver is needed. Copy actual secret environment values into Dokploy's protected environment; never commit them.

The VPS has been verified to pull the SHA-pinned GHCR images anonymously. Admin's GitHub Actions image workflow needs repository Variables for its build inputs: R2 account/bucket identifiers are required for private media URLs; Mapbox public token, GA measurement ID, and VAPID public key enable their respective client features. Keep all private credentials as Actions secrets or VPS environment values; none belong in image tags.

The service repositories publish independently to GHCR. Dokploy Compose runs Admin, RAG, and Presence as separate containers on private networks; Traefik exposes Admin and routes `/presence` to the WebSocket service. Admin owns Drizzle migrations. RAG bootstrap prepares the vector extension/schema before Admin migrations; RAG itself keeps its limited private Postgres access and uses Admin's internal API. Cron and notification dispatch remain lightweight Admin endpoint callers.

Public, Links, and NGL remain Cloudflare Pages deployments. They are not part of the VPS stack, so their servers never receive Admin's internal API credential.

Deployment is promotion by image tag: update affected pins in `production-images.env` and deploy the Compose project through Dokploy. Dokploy must target the existing remote server, not the control-plane host. Configure Dokploy's GitHub source/auto-deploy or trigger a deployment through its API. Do not build app source on the VPS.

`scripts/docker-prod-up.sh` runs migrations first for Admin/RAG or a full rollout; Presence-only updates skip them. Migration order is RAG bootstrap, Admin migrations, then migration verification. The helper pulls and starts images; it never builds. Image pins must be full 40-character Git SHA tags. Rollback overlays the previously running image IDs; database migrations remain applied, so schema changes must remain compatible with the previous app image during rollback. Before enabling Dokploy auto-deploy, verify that its Compose lifecycle preserves this migration-before-runtime ordering.
