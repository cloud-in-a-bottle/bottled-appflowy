#!/bin/bash
# Boot AppFlowy Cloud + GoTrue + Postgres + Redis + MinIO + OIDC
# bridge + nginx for OpenHost.
#
# Topology overview:
#
#   browser → OpenHost router (subdomain appflowy.<zone>; verifies
#                              owner zone_auth, stamps
#                              X-OpenHost-Is-Owner)
#          → container :8080  (nginx)
#                ├─ /_oidc/*          → oidc_bridge.py on :7000
#                ├─ /realms/openhost/* → oidc_bridge.py (Keycloak-shape)
#                ├─ /sso-bounce       → sso_bounce.py on :7100
#                ├─ /gotrue/*         → gotrue on :9999
#                ├─ /api/*            → appflowy_cloud on :8000
#                ├─ /ws*              → appflowy_cloud on :8000 (WebSocket)
#                ├─ /minio-api/*      → minio API on :9000
#                ├─ /minio/*          → minio console on :9001
#                ├─ static assets     → /opt/appflowy-web/html
#                └─ /                 → bouncer (owner+no-jwt) | static SPA
#
# First-boot bootstrap:
#   * Generate strong Postgres + admin + GoTrue JWT + MinIO + OIDC
#     client passwords, persisted under $PERSIST.
#   * Initialise Postgres data dir; create the appflowy DB; create
#     the auth schema (used by gotrue).
#   * Enable the pgvector extension (required for appflowy_cloud's
#     embedding columns even when AI is disabled).
#   * Start postgres, redis, minio in that order.
#   * Run `gotrue migrate` to populate the auth schema.
#   * Start gotrue (it auto-creates the admin user if absent).
#   * Wait for the gotrue admin user, then start appflowy_cloud
#     which runs its own embedded sqlx migrations on first boot.
#   * Start oidc_bridge + sso_bounce + nginx.
#
# Subsequent boots load persisted credentials and skip generation.

set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/appflowy}"
ZONE_DOMAIN="${OPENHOST_ZONE_DOMAIN:-localhost}"
APP_NAME="${OPENHOST_APP_NAME:-appflowy}"
APP_HOST="${APP_NAME}.${ZONE_DOMAIN}"
APP_BASE_URL="https://${APP_HOST}"
APP_WS_URL="wss://${APP_HOST}/ws/v2"

PG_DATA="$PERSIST/postgres"
PG_LOG_DIR="$PERSIST/log"
PG_LOG="$PG_LOG_DIR/postgres.log"
REDIS_DATA="$PERSIST/redis"
MINIO_DATA="$PERSIST/minio"
OIDC_DATA_DIR="$PERSIST/oidc"

# Persisted secrets (one file per concern; 0600 owned by root).
PG_PASSWORD_FILE="$PERSIST/postgres-password.txt"
GOTRUE_ADMIN_PASSWORD_FILE="$PERSIST/gotrue-admin-password.txt"
GOTRUE_JWT_SECRET_FILE="$PERSIST/gotrue-jwt-secret.txt"
MINIO_ACCESS_KEY_FILE="$PERSIST/minio-access-key.txt"
MINIO_SECRET_KEY_FILE="$PERSIST/minio-secret-key.txt"
OIDC_CLIENT_SECRET_FILE="$PERSIST/oidc-client-secret.txt"

mkdir -p "$PERSIST" "$PG_LOG_DIR" "$REDIS_DATA" "$MINIO_DATA" "$OIDC_DATA_DIR"
chown postgres:postgres "$PG_LOG_DIR"
chmod 0750 "$PG_LOG_DIR"

# -----------------------------------------------------------------
# Loopback-public-URL bridge
#
# GoTrue's keycloak provider hardcodes a single base URL for ALL
# of {auth, token, userinfo} endpoints — it doesn't separate the
# browser-facing URL from the server-facing one.  The browser must
# reach the public hostname (`appflowy.<zone>`) for the auth
# endpoint, but server-to-server token/userinfo calls from inside
# the container can't reach the public IP (NAT-loopback / cloud
# firewall blocks the container from talking to its own external
# address).
#
# Workaround: make the public hostname resolve to 127.0.0.1
# inside this container via /etc/hosts, run a second nginx
# listener on :443 with a self-signed cert, and add that cert to
# Go's trusted-CA bundle so GoTrue's HTTPS calls succeed.  The
# browser is unaffected — it still sees the OpenHost outer Caddy's
# Let's Encrypt cert because it never enters this container at all
# for the TLS leg.
# -----------------------------------------------------------------
if ! grep -q "$APP_HOST" /etc/hosts; then
    echo "127.0.0.1 $APP_HOST" >> /etc/hosts
fi

CERT_DIR="$PERSIST/internal-tls"
mkdir -p "$CERT_DIR"
if [[ ! -f "$CERT_DIR/cert.pem" ]]; then
    echo "[start.sh] Generating internal self-signed TLS cert for $APP_HOST"
    # SAN includes the public hostname so GoTrue's TLS handshake
    # passes hostname verification.
    openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
        -keyout "$CERT_DIR/key.pem" \
        -out "$CERT_DIR/cert.pem" \
        -subj "/CN=$APP_HOST" \
        -addext "subjectAltName=DNS:$APP_HOST,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
    chmod 0600 "$CERT_DIR/key.pem"
fi

# Trust the self-signed cert inside this container so Go's
# crypto/x509 default verifier accepts it.  /etc/ssl/certs is
# already on Go's default search path on Debian/Ubuntu.
cp "$CERT_DIR/cert.pem" /usr/local/share/ca-certificates/openhost-appflowy-internal.crt
update-ca-certificates >/dev/null 2>&1 || true

# -----------------------------------------------------------------
# Inject APP_CONFIG into the AppFlowy-Web SPA's index.html
#
# The upstream docker-entrypoint.sh sed-rewrites index.html on
# every container start to inject the runtime config that the SPA
# reads from window.__APP_CONFIG__.  We've already discarded that
# entrypoint by copying just the static bundle, so we replicate
# the rewrite here.  The replacement is idempotent (we delete any
# previous injection first via grep -v).
# -----------------------------------------------------------------
INDEX_HTML=/opt/appflowy-web/html/index.html
INDEX_BACKUP=/opt/appflowy-web/html/index.html.orig
if [[ ! -f "$INDEX_BACKUP" ]]; then
    cp "$INDEX_HTML" "$INDEX_BACKUP"
fi
CONFIG_SCRIPT="<script>window.__APP_CONFIG__={APPFLOWY_BASE_URL:'${APP_BASE_URL}',APPFLOWY_GOTRUE_BASE_URL:'${APP_BASE_URL}/gotrue',APPFLOWY_WS_BASE_URL:'${APP_WS_URL}'};</script>"
# Re-render from the original each boot so URL changes propagate.
sed "s|</head>|${CONFIG_SCRIPT}</head>|" "$INDEX_BACKUP" > "$INDEX_HTML"

# -----------------------------------------------------------------
# Secret generation
# -----------------------------------------------------------------

# tr_strong: read /dev/urandom to produce a 32-char strong-entropy
# alphanumeric password.  Used for every persisted credential.
gen_secret() {
    local length="${1:-32}"
    head -c $((length * 2)) /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

ensure_secret() {
    local file="$1"
    local length="${2:-32}"
    if [[ ! -f "$file" ]]; then
        echo "[start.sh] Generating $(basename "$file")"
        gen_secret "$length" > "$file"
        chmod 0600 "$file"
    fi
}

ensure_secret "$PG_PASSWORD_FILE"
ensure_secret "$GOTRUE_ADMIN_PASSWORD_FILE"
ensure_secret "$GOTRUE_JWT_SECRET_FILE" 64
ensure_secret "$MINIO_ACCESS_KEY_FILE" 20
ensure_secret "$MINIO_SECRET_KEY_FILE" 40
ensure_secret "$OIDC_CLIENT_SECRET_FILE" 48

PG_PASSWORD="$(cat "$PG_PASSWORD_FILE")"
GOTRUE_ADMIN_PASSWORD="$(cat "$GOTRUE_ADMIN_PASSWORD_FILE")"
GOTRUE_JWT_SECRET="$(cat "$GOTRUE_JWT_SECRET_FILE")"
MINIO_ACCESS_KEY="$(cat "$MINIO_ACCESS_KEY_FILE")"
MINIO_SECRET_KEY="$(cat "$MINIO_SECRET_KEY_FILE")"
OIDC_CLIENT_SECRET="$(cat "$OIDC_CLIENT_SECRET_FILE")"
OIDC_CLIENT_ID="openhost-appflowy"

GOTRUE_ADMIN_EMAIL="admin@${ZONE_DOMAIN}"
OWNER_EMAIL="owner@${ZONE_DOMAIN}"

# -----------------------------------------------------------------
# Postgres bootstrap
# -----------------------------------------------------------------

PG_BIN="/usr/lib/postgresql/16/bin"

if [[ ! -d "$PG_DATA/base" ]]; then
    echo "[start.sh] First boot: initialising Postgres data dir at $PG_DATA"
    mkdir -p "$PG_DATA"
    chown postgres:postgres "$PG_DATA"
    chmod 0700 "$PG_DATA"
    gosu postgres "$PG_BIN/initdb" -D "$PG_DATA" --auth=trust --username=postgres --encoding=UTF8 --locale=C 2>&1 | tail -10
fi

sed -i "s/^#\?listen_addresses.*/listen_addresses = '127.0.0.1'/" "$PG_DATA/postgresql.conf"
sed -i "s/^#\?port .*/port = 5432/"                                 "$PG_DATA/postgresql.conf"
# Bump max_connections — appflowy_cloud + worker + ai + search +
# gotrue can collectively open ~80 connections.  Default 100 is
# borderline; 200 leaves headroom for SUPERUSER reserves.
sed -i "s/^#\?max_connections.*/max_connections = 200/"             "$PG_DATA/postgresql.conf"

echo "[start.sh] Starting Postgres on 127.0.0.1:5432"
gosu postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_LOG" -w start

# Wait until Postgres is accepting connections.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if gosu postgres "$PG_BIN/pg_isready" -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Idempotent role + DB + schema setup.  Both AppFlowy Cloud and
# GoTrue connect with the SAME postgres role (matches the upstream
# docker-compose); they're segregated by schema (appflowy_cloud
# uses public, gotrue uses auth via search_path).
PG_ROLE_EXISTS="$(gosu postgres "$PG_BIN/psql" -tAc "SELECT 1 FROM pg_roles WHERE rolname='postgres'" || true)"
gosu postgres "$PG_BIN/psql" -c "ALTER ROLE postgres WITH PASSWORD '$PG_PASSWORD';" >/dev/null

# AppFlowy Cloud calls the DB ``postgres``; GoTrue uses the same DB
# with search_path=auth.  The ``auth`` schema is created on first
# `auth migrate`; we only need to make sure pgvector is enabled.
gosu postgres "$PG_BIN/psql" -c "CREATE EXTENSION IF NOT EXISTS vector;" -d postgres >/dev/null
# AppFlowy uses these too based on its migrations.
gosu postgres "$PG_BIN/psql" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" -d postgres >/dev/null
gosu postgres "$PG_BIN/psql" -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";' -d postgres >/dev/null

# -----------------------------------------------------------------
# Redis
# -----------------------------------------------------------------

echo "[start.sh] Starting Redis on 127.0.0.1:6379"
chown -R appflowy:appflowy "$REDIS_DATA"
# Persistence: AOF on with everysec fsync + RDB snapshot every 5
# minutes if at least one key changed.  AppFlowy uses Redis for
# the import_task_stream queue (Notion zip imports etc.) — without
# persistence, an unfinished import gets dropped on container
# restart and the visitor's "we'll notify you" toast never resolves.
# everysec is the standard durability/perf trade-off; we lose at
# most 1s of writes on a hard crash.
gosu appflowy redis-server \
    --bind 127.0.0.1 \
    --port 6379 \
    --dir "$REDIS_DATA" \
    --save "300 1" \
    --appendonly yes \
    --appendfsync everysec \
    --daemonize no \
    --logfile "" \
    > "$PERSIST/log/redis.log" 2>&1 &
REDIS_PID=$!

# -----------------------------------------------------------------
# MinIO
# -----------------------------------------------------------------

echo "[start.sh] Starting MinIO on 127.0.0.1:9000 (api) / 127.0.0.1:9001 (console)"
chown -R appflowy:appflowy "$MINIO_DATA"
MINIO_ROOT_USER="$MINIO_ACCESS_KEY" \
MINIO_ROOT_PASSWORD="$MINIO_SECRET_KEY" \
MINIO_BROWSER_REDIRECT_URL="${APP_BASE_URL}/minio" \
gosu appflowy /usr/local/bin/minio server "$MINIO_DATA" \
    --address 127.0.0.1:9000 \
    --console-address 127.0.0.1:9001 \
    > "$PERSIST/log/minio.log" 2>&1 &
MINIO_PID=$!

# Wait for MinIO to be ready.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf "http://127.0.0.1:9000/minio/health/live" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# -----------------------------------------------------------------
# GoTrue migrations + start
# -----------------------------------------------------------------

GOTRUE_DB_URL="postgres://postgres:${PG_PASSWORD}@127.0.0.1:5432/postgres?search_path=auth&sslmode=disable"

echo "[start.sh] Running gotrue migrations"
# `gotrue migrate` requires the same set of env vars as the main
# server even though most are unused — API_EXTERNAL_URL,
# GOTRUE_JWT_SECRET, GOTRUE_SITE_URL all have to be present or
# config validation fails.  Pass the full prod env so the same
# values flow through.
GOTRUE_DB_DRIVER=postgres \
GOTRUE_DATABASE_URL="$GOTRUE_DB_URL" \
DATABASE_URL="$GOTRUE_DB_URL" \
GOTRUE_MIGRATIONS_PATH=/opt/openhost-appflowy/gotrue-migrations \
GOTRUE_API_HOST=127.0.0.1 \
GOTRUE_API_PORT=9999 \
PORT=9999 \
GOTRUE_SITE_URL="appflowy-flutter://" \
API_EXTERNAL_URL="${APP_BASE_URL}/gotrue" \
GOTRUE_JWT_SECRET="$GOTRUE_JWT_SECRET" \
gosu appflowy /usr/local/bin/gotrue migrate \
    2>&1 | sed 's/^/[gotrue-migrate] /' || true

echo "[start.sh] Starting GoTrue on 127.0.0.1:9999"
GOTRUE_DB_DRIVER=postgres \
GOTRUE_DATABASE_URL="$GOTRUE_DB_URL" \
DATABASE_URL="$GOTRUE_DB_URL" \
GOTRUE_API_HOST=127.0.0.1 \
GOTRUE_API_PORT=9999 \
PORT=9999 \
GOTRUE_SITE_URL="appflowy-flutter://" \
GOTRUE_URI_ALLOW_LIST="**" \
API_EXTERNAL_URL="${APP_BASE_URL}/gotrue" \
GOTRUE_JWT_SECRET="$GOTRUE_JWT_SECRET" \
GOTRUE_JWT_EXP=604800 \
GOTRUE_JWT_ADMIN_GROUP_NAME=supabase_admin \
GOTRUE_DISABLE_SIGNUP=false \
GOTRUE_MAILER_AUTOCONFIRM=true \
GOTRUE_ADMIN_EMAIL="$GOTRUE_ADMIN_EMAIL" \
GOTRUE_ADMIN_PASSWORD="$GOTRUE_ADMIN_PASSWORD" \
GOTRUE_MAILER_URLPATHS_CONFIRMATION=/gotrue/verify \
GOTRUE_MAILER_URLPATHS_INVITE=/gotrue/verify \
GOTRUE_MAILER_URLPATHS_RECOVERY=/gotrue/verify \
GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE=/gotrue/verify \
GOTRUE_EXTERNAL_KEYCLOAK_ENABLED=true \
GOTRUE_EXTERNAL_KEYCLOAK_CLIENT_ID="$OIDC_CLIENT_ID" \
GOTRUE_EXTERNAL_KEYCLOAK_SECRET="$OIDC_CLIENT_SECRET" \
GOTRUE_EXTERNAL_KEYCLOAK_REDIRECT_URI="${APP_BASE_URL}/gotrue/callback" \
GOTRUE_EXTERNAL_KEYCLOAK_URL="${APP_BASE_URL}/realms/openhost" \
gosu appflowy /usr/local/bin/gotrue \
    > "$PERSIST/log/gotrue.log" 2>&1 &
GOTRUE_PID=$!

# Wait for gotrue health.
echo "[start.sh] Waiting for gotrue readiness..."
GOTRUE_READY=0
for i in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:9999/health" >/dev/null 2>&1; then
        GOTRUE_READY=1
        echo "[start.sh] gotrue ready after ${i}s"
        break
    fi
    if ! kill -0 "$GOTRUE_PID" 2>/dev/null; then
        echo "[start.sh] gotrue exited before becoming ready; tail of log:"
        tail -30 "$PERSIST/log/gotrue.log" || true
        kill -TERM "$REDIS_PID" "$MINIO_PID" 2>/dev/null || true
        gosu postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m fast || true
        exit 1
    fi
    sleep 1
done
if [[ "$GOTRUE_READY" != "1" ]]; then
    echo "[start.sh] gotrue did not become ready within 60s"
    tail -30 "$PERSIST/log/gotrue.log" || true
    exit 1
fi

# -----------------------------------------------------------------
# AppFlowy Cloud
# -----------------------------------------------------------------

APPFLOWY_DB_URL="postgres://postgres:${PG_PASSWORD}@127.0.0.1:5432/postgres"

echo "[start.sh] Starting appflowy_cloud on 127.0.0.1:8000"
APP_ENVIRONMENT=production \
RUST_LOG=warn \
PORT=8000 \
APPFLOWY_ENVIRONMENT=production \
APPFLOWY_DATABASE_URL="$APPFLOWY_DB_URL" \
APPFLOWY_REDIS_URI="redis://127.0.0.1:6379" \
APPFLOWY_GOTRUE_JWT_SECRET="$GOTRUE_JWT_SECRET" \
APPFLOWY_GOTRUE_BASE_URL="http://127.0.0.1:9999" \
APPFLOWY_S3_CREATE_BUCKET=true \
APPFLOWY_S3_USE_MINIO=true \
APPFLOWY_S3_MINIO_URL="http://127.0.0.1:9000" \
APPFLOWY_S3_ACCESS_KEY="$MINIO_ACCESS_KEY" \
APPFLOWY_S3_SECRET_KEY="$MINIO_SECRET_KEY" \
APPFLOWY_S3_BUCKET=appflowy \
APPFLOWY_S3_REGION=us-east-1 \
APPFLOWY_S3_PRESIGNED_URL_ENDPOINT="${APP_BASE_URL}/minio-api" \
APPFLOWY_ACCESS_CONTROL=true \
APPFLOWY_DATABASE_MAX_CONNECTIONS=40 \
APPFLOWY_BASE_URL="$APP_BASE_URL" \
APPFLOWY_WEB_URL="$APP_BASE_URL" \
AI_ENABLED=false \
AI_OPENAI_API_KEY= \
APPFLOWY_INDEXER_DATABASE_ENABLED=false \
APPFLOWY_KEYWORD_SEARCH_ENABLED=false \
APPFLOWY_SEARCH_SERVICE_URL=http://127.0.0.1:4002 \
SIGNUP_WHITELIST_ENABLED=false \
gosu appflowy /usr/local/bin/appflowy_cloud \
    > "$PERSIST/log/appflowy_cloud.log" 2>&1 &
APPFLOWY_PID=$!

echo "[start.sh] Waiting for appflowy_cloud readiness (migrations + bind)..."
APPFLOWY_READY=0
for i in $(seq 1 180); do
    if curl -sf "http://127.0.0.1:8000/api/health" >/dev/null 2>&1; then
        APPFLOWY_READY=1
        echo "[start.sh] appflowy_cloud ready after ${i}s"
        break
    fi
    if ! kill -0 "$APPFLOWY_PID" 2>/dev/null; then
        echo "[start.sh] appflowy_cloud exited before becoming ready; tail of log:"
        tail -50 "$PERSIST/log/appflowy_cloud.log" || true
        kill -TERM "$GOTRUE_PID" "$REDIS_PID" "$MINIO_PID" 2>/dev/null || true
        gosu postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m fast || true
        exit 1
    fi
    sleep 1
done
if [[ "$APPFLOWY_READY" != "1" ]]; then
    echo "[start.sh] appflowy_cloud did not become ready within 180s"
    tail -50 "$PERSIST/log/appflowy_cloud.log" || true
    exit 1
fi

# -----------------------------------------------------------------
# AppFlowy Worker
# -----------------------------------------------------------------
#
# Background job runner for Notion-zip imports (and a few other
# long-running tasks).  appflowy_cloud queues each import on the
# ``import_task_stream`` Redis stream; the worker polls the stream,
# downloads the user's zip from MinIO, parses the Notion export,
# and materialises the pages in the workspace.  Without this
# process running, the visitor sees the "we'll notify you when
# it's done" toast and the import sits in the queue forever.
#
# Same DB / Redis / S3 settings as appflowy_cloud — the worker
# shares the same backing services and just consumes a different
# Redis stream.  We launch it AFTER appflowy_cloud's readiness
# check so we know the DB schema migrations have completed.

echo "[start.sh] Starting appflowy_worker"
APP_ENVIRONMENT=production \
RUST_LOG=warn \
APPFLOWY_ENVIRONMENT=production \
APPFLOWY_WORKER_REDIS_URL="redis://127.0.0.1:6379" \
APPFLOWY_WORKER_ENVIRONMENT=production \
APPFLOWY_WORKER_DATABASE_URL="$APPFLOWY_DB_URL" \
APPFLOWY_WORKER_DATABASE_NAME=postgres \
APPFLOWY_WORKER_IMPORT_TICK_INTERVAL=30 \
APPFLOWY_S3_USE_MINIO=true \
APPFLOWY_S3_MINIO_URL="http://127.0.0.1:9000" \
APPFLOWY_S3_ACCESS_KEY="$MINIO_ACCESS_KEY" \
APPFLOWY_S3_SECRET_KEY="$MINIO_SECRET_KEY" \
APPFLOWY_S3_BUCKET=appflowy \
APPFLOWY_S3_REGION=us-east-1 \
APPFLOWY_S3_PRESIGNED_URL_ENDPOINT="${APP_BASE_URL}/minio-api" \
gosu appflowy /usr/local/bin/appflowy_worker \
    > "$PERSIST/log/appflowy_worker.log" 2>&1 &
WORKER_PID=$!

# -----------------------------------------------------------------
# OIDC bridge + SSO bouncer
# -----------------------------------------------------------------

OIDC_PUBLIC_BASE="$APP_BASE_URL"

echo "[start.sh] Starting OIDC bridge on 127.0.0.1:7000"
chown -R appflowy:appflowy "$OIDC_DATA_DIR"
cd /opt/openhost-appflowy
OIDC_PUBLIC_BASE="$OIDC_PUBLIC_BASE" \
OIDC_CLIENT_ID="$OIDC_CLIENT_ID" \
OIDC_CLIENT_SECRET="$OIDC_CLIENT_SECRET" \
OIDC_DATA_DIR="$OIDC_DATA_DIR" \
OPENHOST_ZONE_DOMAIN="$ZONE_DOMAIN" \
gosu appflowy python3 -m uvicorn --host 127.0.0.1 --port 7000 --log-level warning --app-dir /opt/openhost-appflowy oidc_bridge:app \
    > "$PERSIST/log/oidc_bridge.log" 2>&1 &
BRIDGE_PID=$!

echo "[start.sh] Starting SSO bouncer on 127.0.0.1:7100"
OIDC_PUBLIC_BASE="$OIDC_PUBLIC_BASE" \
OIDC_CLIENT_ID="$OIDC_CLIENT_ID" \
APP_HOST="$APP_HOST" \
gosu appflowy python3 -m uvicorn --host 127.0.0.1 --port 7100 --log-level warning --app-dir /opt/openhost-appflowy sso_bounce:app \
    > "$PERSIST/log/sso_bounce.log" 2>&1 &
BOUNCE_PID=$!

# -----------------------------------------------------------------
# nginx
# -----------------------------------------------------------------

echo "[start.sh] Starting nginx on 0.0.0.0:8080"
nginx -g 'daemon off;' &
NGINX_PID=$!

# -----------------------------------------------------------------
# Bootstrap (background — non-fatal if it lags)
# -----------------------------------------------------------------

(
    GOTRUE_BASE_URL="http://127.0.0.1:9999" \
    GOTRUE_ADMIN_EMAIL="$GOTRUE_ADMIN_EMAIL" \
    GOTRUE_ADMIN_PASSWORD="$GOTRUE_ADMIN_PASSWORD" \
    OWNER_EMAIL="$OWNER_EMAIL" \
    python3 /opt/openhost-appflowy/bootstrap.py 2>&1 | sed 's/^/[bootstrap] /'
) &

# -----------------------------------------------------------------
# Supervision
# -----------------------------------------------------------------

cleanup() {
    echo "[start.sh] Cleaning up child processes..."
    kill -TERM "$NGINX_PID" "$APPFLOWY_PID" "$WORKER_PID" "$GOTRUE_PID" "$BRIDGE_PID" "$BOUNCE_PID" "$REDIS_PID" "$MINIO_PID" 2>/dev/null || true
    gosu postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m fast 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup TERM INT

# Note: the worker is intentionally NOT in the wait-n list. If the
# worker crashes (e.g. on a malformed import zip) we don't want to
# bring down the whole stack with it; let the next boot pick up
# the failure log.  appflowy_cloud + nginx + gotrue are critical
# and stay in the wait set.
set +e
wait -n "$NGINX_PID" "$APPFLOWY_PID" "$GOTRUE_PID" "$BRIDGE_PID" "$BOUNCE_PID" "$REDIS_PID" "$MINIO_PID"
EXIT_CODE=$?
set -e

echo "[start.sh] Child exited (code=$EXIT_CODE); shutting down"
cleanup
exit "$EXIT_CODE"
