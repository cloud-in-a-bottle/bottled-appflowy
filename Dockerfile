# AppFlowy Cloud + GoTrue + Postgres-pgvector + Redis + MinIO + an
# OIDC-bridge sidecar packaged as a single OpenHost-deployable container.
#
# Topology:
#
#   browser → OpenHost router (subdomain appflowy.<zone>; verifies
#                              owner zone_auth, stamps
#                              X-OpenHost-Is-Owner)
#          → container :8080  (nginx)
#                ├─ /_oidc/*          → oidc_bridge.py on :7000
#                ├─ /realms/openhost/* → oidc_bridge.py (Keycloak-shape paths)
#                ├─ /sso-bounce       → sso_bounce.py on :7100
#                ├─ /gotrue/*         → gotrue on :9999
#                ├─ /api/*            → appflowy_cloud on :8000
#                ├─ /ws*              → appflowy_cloud on :8000 (WebSocket)
#                ├─ /minio-api/*      → minio API on :9000
#                ├─ /minio/*          → minio console on :9001
#                ├─ static assets     → /opt/appflowy-web/html
#                └─ /                 → bouncer (owner+no-jwt) | static SPA
#
# Internal services launched by start.sh (no s6 / supervisord — bash
# `wait -n` like openhost-lemmy):
#
#   * postgres (16 + pgvector) — bundled DB.
#   * redis (apt) — appflowy_cloud cache + worker queue.
#   * minio (binary download) — S3-compatible blob store.
#   * gotrue — copied from upstream alpine image (Go static binary,
#     runs on glibc with no fuss).
#   * appflowy_cloud — copied from upstream Ubuntu 24.04 image
#     (dynamically linked, so we pin our base to noble for libssl
#     compatibility).
#   * oidc_bridge — Python Starlette OIDC provider, Keycloak-shape
#     URLs so GoTrue's external_keycloak_* settings can talk to it.
#   * sso_bounce — owner SSO redirect helper.
#   * nginx — front-door router on :8080.
#
# Static AppFlowy-Web SPA assets are copied from
# appflowyinc/appflowy_web:latest's /usr/share/nginx/html and served
# directly by our nginx.  Bun-based SSR routes are NOT replicated;
# `/app/*` routes still work via client-side routing on the SPA.

# Stage 1: appflowy_cloud (binary + libs from upstream Ubuntu 24.04 image).
FROM appflowyinc/appflowy_cloud:latest AS appflowy-cloud-source

# Stage 2: gotrue (Go static binary from upstream Alpine image; runs
# fine on glibc since CGO_ENABLED=0).  We grab the migrations dir
# from this image too — the binary applies them on `auth migrate`.
FROM appflowyinc/gotrue:latest AS gotrue-source

# Stage 3: AppFlowy-Web static assets.  We discard the Bun runtime
# and only keep the pre-built SPA bundle from /usr/share/nginx/html
# — the SPA does its own routing client-side, so the Bun SSR layer
# is optional for our purposes.
FROM appflowyinc/appflowy_web:latest AS appflowy-web-source

# Stage 4: final image.  Ubuntu 24.04 noble matches the upstream
# appflowy_cloud build environment so the dynamically-linked
# appflowy_cloud binary (libssl/libcrypto/libbz2/libm) finds matching
# library versions.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# System deps.  Notes:
#   * postgresql-16 + postgresql-16-pgvector: AppFlowy Cloud requires
#     pgvector for AI embeddings columns even when AI features are
#     disabled, because the schema migrations always run and reference
#     the vector extension.
#   * redis-server: cache + worker queue.
#   * nginx: front-door router.
#   * python3 + python3-jwt + python3-cryptography + python3-starlette
#     + python3-uvicorn: OIDC bridge.  Apt names match the lemmy
#     image so we don't have to pip-install in the build.
#   * curl, ca-certificates, tini, gosu, procps: lifecycle / readiness
#     plumbing.
#   * libssl3, libcrypto, libbz2: appflowy_cloud's runtime deps —
#     should already be in noble's base.  Listed explicitly so a
#     future base image swap doesn't silently break.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        nginx \
        openssl \
        redis-server \
        python3 \
        python3-starlette \
        python3-jwt \
        python3-cryptography \
        python3-uvicorn \
        tini \
        gosu \
        procps \
        libssl3 \
        libbz2-1.0 \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default

# PostgreSQL 16 + pgvector from pgdg.  Ubuntu 24.04's universe ships
# postgresql-16 directly, but for pgvector we need pgdg (the
# postgresql-16-pgvector package isn't in main).  Install both from
# pgdg so the versions match.
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg \
 && echo "deb http://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends \
        postgresql-16 \
        postgresql-client-16 \
        postgresql-16-pgvector \
 && rm -rf /var/lib/apt/lists/*

# MinIO server binary.  Pin to a recent stable release; minio's
# upstream binary is statically-linked Go, runs fine on Ubuntu.
# 2025-04-22 release is the current LTS line.
RUN curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.2025-04-22T22-12-26Z \
        -o /usr/local/bin/minio \
 && chmod +x /usr/local/bin/minio

# Copy gotrue from the upstream Alpine image.  Despite living on a
# musl-libc filesystem, the binary itself was built CGO_ENABLED=0
# and runs unchanged on glibc.  We also copy /migrations because
# `auth migrate` reads them at runtime.
COPY --from=gotrue-source /auth /usr/local/bin/gotrue
COPY --from=gotrue-source /migrations /opt/openhost-appflowy/gotrue-migrations

# Copy appflowy_cloud binary from the upstream noble image.
COPY --from=appflowy-cloud-source /usr/local/bin/appflowy_cloud /usr/local/bin/appflowy_cloud

# Copy the AppFlowy-Web static SPA bundle.  We serve this from
# nginx without the Bun-based SSR layer; the SPA does its own
# client-side routing for /app/<workspace>/<doc> URLs, so SEO is
# the only thing we lose, and a single-tenant zone owner doesn't
# need SEO.
COPY --from=appflowy-web-source /usr/share/nginx/html /opt/appflowy-web/html

# Create the appflowy unprivileged user.  UID 1500 to avoid clashing
# with default _apt/messagebus etc. system users (matches
# openhost-lemmy convention).
RUN useradd --system --uid 1500 --user-group --no-create-home --shell /usr/sbin/nologin appflowy

# Application files.
COPY nginx.conf       /etc/nginx/nginx.conf
COPY oidc_bridge.py   /opt/openhost-appflowy/oidc_bridge.py
COPY sso_bounce.py    /opt/openhost-appflowy/sso_bounce.py
COPY bootstrap.py     /opt/openhost-appflowy/bootstrap.py
COPY start.sh         /opt/openhost-appflowy/start.sh
RUN chmod +x /opt/openhost-appflowy/start.sh

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/openhost-appflowy/start.sh"]
