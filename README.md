# openhost-appflowy

Placeholder — AppFlowy Cloud is not yet shipped on OpenHost.

## Why a placeholder?

AppFlowy Cloud is a multi-service stack:

  * **PostgreSQL** — primary metadata DB.
  * **GoTrue** — Supabase's auth service.  Handles user sessions,
    OAuth/OIDC providers, JWT minting.  Configured via env vars
    AND a postgres-stored auth schema.
  * **appflowy-cloud** — main API server.  Reads the GoTrue JWT
    from the `Authorization` header on every request.
  * **appflowy-history** — version-history service.
  * **appflowy-worker** — background-job runner (notifications,
    indexing).
  * **MinIO** — S3-compatible blob store for document attachments.
    `appflowy-cloud` mints signed URLs against MinIO for blob
    uploads/downloads.
  * **Redis** — caching + ephemeral state.
  * **Nginx** — request routing layer in front of the above.

Bundling all of this into a single OpenHost container is feasible
but non-trivial:

  * GoTrue's OIDC client config has to be wired through env vars
    **AND** the postgres-stored auth schema.  A Pattern D OIDC
    bridge would need both an HTTP shim (like
    `openhost-immich`'s `oidc-bridge/server.py`) and a SQL bootstrap
    step that registers the OpenHost OIDC client in
    `auth.providers`.
  * MinIO needs to be reachable over loopback under a stable URL
    for `appflowy-cloud`'s signed-URL generation.  S3 client
    libraries embedded in `appflowy-cloud` use the URL it was
    handed by `appflowy-cloud`'s config; getting that URL to also
    be reachable from the browser (for client-side blob uploads)
    requires either an `appflowy-cloud` config patch or a
    transparent nginx routing layer.
  * `appflowy-cloud` expects a specific Postgres migration history
    populated by its own migration runner; a clean first-boot
    flow would need ~5 minutes of orchestration work alone.

## What this repo ships

A tiny Alpine image running busybox `httpd` serving a static
"coming soon" page on port 8080 so the OpenHost slot is reserved
and `appflowy.<zone>` doesn't 404 outright.

## A full implementation would …

Model itself on `openhost-lemmy`:

  1. `Dockerfile` based on `debian:bookworm-slim` with apt-installed
     postgres-15 + redis + nginx + python3 + gotrue + minio + the
     appflowy-cloud / appflowy-history / appflowy-worker binaries
     copied from their respective upstream images via multi-stage
     COPY.
  2. `start.sh` that:
     * Initialises the Postgres data dir on first boot.
     * Generates a strong GoTrue JWT secret + OIDC client secret.
     * Bootstraps GoTrue's `auth` schema via `goose migrate` or
       similar.
     * INSERTs an OIDC provider row pointing at `https://<zone>/_oidc/*`.
     * Starts MinIO with a generated access key / secret.
     * Starts appflowy-cloud, appflowy-history, appflowy-worker
       with the right `DATABASE_URL` / `REDIS_URL` /
       `S3_*` / `GOTRUE_*` env vars.
     * Starts nginx + the OIDC bridge sidecar (lifted from
       `openhost-lemmy`/`oidc_bridge.py`).
  3. An `oidc_bridge.py` near-verbatim from `openhost-lemmy`.
  4. A `bootstrap.py` that, after services are up, calls
     `appflowy-cloud`'s `POST /api/user/register` with the OIDC
     bridge's owner email so the user row exists before first
     OIDC sign-in (otherwise GoTrue's first-sign-in path needs
     a working SMTP relay for confirmation emails).
  5. An `nginx.conf` that routes `/_oidc/*` to the bridge,
     `/gotrue/*` to GoTrue, `/api/*` to appflowy-cloud, `/minio/*`
     to MinIO, and everything else to the appflowy-cloud SPA.

The complete implementation is roughly 600 lines of
configuration + scripts.  It's a 1-day task; not a 1-hour task.

## Status

Tracking issue: pull requests welcome.  Until then, point your
clients at a separately-deployed AppFlowy Cloud or use AppFlowy's
local-only mode.
