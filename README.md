# VPS deployment

This repository contains deployment configuration only: production Compose and migration/rollout helpers. Immutable image tags live directly in Compose so a pin change is reviewable and triggers the existing Dokploy source. Dokploy at `cloud.nrflabs.net` owns deployment to its configured remote server. No extra DNS name or custom webhook receiver is needed. Keep actual secret environment values in Dokploy's protected environment; never commit them.

The VPS has been verified to pull the SHA-pinned GHCR images anonymously. Admin's GitHub Actions image workflow needs repository Variables for its build inputs: R2 account/bucket identifiers are required for private media URLs; Mapbox public token, GA measurement ID, and VAPID public key enable their respective client features. Keep all private credentials as Actions secrets or VPS environment values; none belong in image tags.

The service repositories publish independently to GHCR. Dokploy Compose runs Admin, RAG, and Presence as separate containers on private networks; Traefik exposes Admin and routes `/presence` to the WebSocket service. Admin owns Drizzle migrations. RAG bootstrap prepares the vector extension/schema before Admin migrations; RAG itself keeps its limited private Postgres access and uses Admin's internal API. Cron and notification dispatch remain lightweight Admin endpoint callers.

Public, Links, and NGL remain Cloudflare Pages deployments. They are not part of the VPS stack, so their servers never receive Admin's internal API credential.

Deployment is promotion by image tag: update affected immutable tags in `docker-compose.yml` and let Dokploy deploy the Compose project. Dokploy must target the existing remote server, not the control-plane host. Do not build app source on the VPS.

The Compose dependency graph makes RAG bootstrap complete first, then runs Admin migrations and migration verification, and only then starts Admin and RAG. A failed bootstrap or migration blocks the dependent runtime service. This ordering is declarative so Dokploy's normal Compose deploy path preserves it without a separate receiver or host script. Image pins must be full 40-character Git SHA tags. Rollback overlays the previously running image IDs; database migrations remain applied, so schema changes must remain compatible with the previous app image during rollback.
