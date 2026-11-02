# VPS deployment candidate

This repository contains deployment configuration only: production Compose, a pull-based HMAC GitHub webhook receiver, deploy/migration scripts, and a non-secret `production-images.env` file pinning immutable image tags. Copy actual secret environment values into the VPS-provided `.env`; never commit them.

The VPS needs read access to GHCR packages (`docker login ghcr.io` with a read-only package token) unless packages are deliberately published public. Admin's GitHub Actions image workflow also needs repository Variables for its public build inputs: Turnstile site key, Mapbox public token, GA measurement ID, VAPID public key, and R2 account/bucket identifiers. Keep all private credentials as Actions secrets or VPS environment values; none belong in image tags.

The service repositories publish independently to GHCR. VPS Compose runs Admin, RAG, and Presence as separate containers on private networks; Traefik exposes Admin and routes `/presence` to the WebSocket service. Admin owns Drizzle migrations. RAG bootstrap prepares the vector extension/schema before Admin migrations; RAG itself keeps its limited private Postgres access and uses Admin's internal API. Cron and notification dispatch remain lightweight Admin endpoint callers.

Public, Links, and NGL remain Cloudflare Pages deployments. They are not part of the VPS stack, so their servers never receive Admin's internal API credential.

Deployment is promotion by image tag: update affected pins in `production-images.env` and push to `main`. Configure GitHub's `push` webhook with an HMAC secret to reach the receiver. The receiver pulls the deployment repo; it never accepts source files from the request. It maps changed pins to services and records a revision only after a healthy rollout. Failed deliveries release their duplicate marker so GitHub can retry. Documentation-only commits do not restart services.

Run `scripts/docker-prod-up.sh` for rollout. It automatically runs `scripts/docker-prod-migrate.sh` first when Admin or RAG changes (and for a full rollout); Presence-only and scheduler-only updates skip migrations. Migration order is RAG bootstrap, Admin migrations, then migration verification. The deploy script only pulls and starts images; it never builds. Image pins must be full 40-character Git SHA tags. Rollback overlays the previously running image IDs; database migrations remain applied, so schema changes must remain compatible with the previous app image during rollback. No service source or workspace lockfile belongs here.

The webhook server defaults to loopback on port 9010. Put it behind the host's existing TLS ingress. Configure `PORTFOLIO_WEBHOOK_SECRET`, `PORTFOLIO_WEBHOOK_REPO_DIR`, and `PORTFOLIO_WEBHOOK_DEPLOY_SCRIPT` in the host's protected service environment; keep state under `/var/lib/portfolio-webhook` and logs under `/var/log/portfolio-webhook`. Restrict the GitHub webhook to `push` on `main`.
