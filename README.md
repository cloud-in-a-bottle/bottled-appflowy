# openhost-appflowy

[AppFlowy Cloud](https://github.com/AppFlowy-IO/AppFlowy-Cloud) — a
Notion-alternative collaborative workspace — packaged as an OpenHost
app, accessed via SSO with no application-level auth on the public
SPA.

## What you get

- AppFlowy running on `https://appflowy.<zone>/` with TLS terminated
  by the OpenHost outer Caddy.
- Only the zone owner can reach the SPA; the OpenHost router gates
  access on zone JWTs and the OIDC bridge enforces "owner only" by
  rejecting any /authorize request without `X-OpenHost-Is-Owner`.
- The AppFlowy desktop / mobile native apps can connect to
  `https://appflowy.<zone>` as their server URL after first signing
  in via the web (so the GoTrue session has been minted).
- Persistent state under `/data/app_data/appflowy/`:
  - `postgres/` — DB cluster (AppFlowy + GoTrue's `auth` schema)
  - `minio/` — uploaded document attachments
  - `oidc/` — RSA signing key for the OIDC bridge
  - `redis/` — cache (transient; wiped on restart)
  - `log/` — child-process stdout/stderr
  - `*.txt` — generated secrets

## Architecture

```
browser
   │
   ▼
OpenHost outer Caddy (TLS)
   │
   ▼
OpenHost router (stamps X-OpenHost-Is-Owner: true on owner JWTs)
   │
   ▼
container :8080  (nginx)
       ├─ /_oidc/*           → oidc_bridge (Python on :7000)
       ├─ /realms/openhost/* → oidc_bridge (Keycloak-shape paths,
       │                       what GoTrue's external_keycloak fetcher
       │                       talks to)
       ├─ /sso-bounce        → sso_bounce (Python on :7100)
       ├─ /gotrue/*          → gotrue (Go static binary on :9999)
       ├─ /api/*             → appflowy_cloud (Rust binary on :8000)
       ├─ /ws*               → appflowy_cloud (WebSocket)
       ├─ /minio-api/*       → MinIO API (:9000)  -- presigned URL traffic
       ├─ /minio/*           → MinIO console (:9001) -- admin UI
       └─ /                  → AppFlowy-Web SPA bundle
                              (copied from upstream image's
                              /usr/share/nginx/html, served as
                              static files; bouncer redirects
                              owners through SSO on first hit)
```

Internal services (started by `start.sh`, supervised via bash
`wait -n`):

| Process          | Port  | Purpose                                       |
| ---------------- | ----- | --------------------------------------------- |
| postgres-16      | 5432  | metadata DB + GoTrue's `auth` schema          |
| redis            | 6379  | appflowy_cloud cache + worker queue           |
| minio            | 9000/9001 | S3-compatible blob store                  |
| gotrue           | 9999  | Supabase auth — issues GoTrue JWTs            |
| appflowy_cloud   | 8000  | main API, document collab, WebSocket          |
| oidc_bridge      | 7000  | OIDC IdP (Keycloak-shape) backed by zone auth |
| sso_bounce       | 7100  | redirect helper for owner first-hit flow      |
| nginx            | 8080  | front-door router                             |

## What's intentionally omitted

- **`appflowy_ai`** (semantic search, GPT summaries) — needs an
  OpenAI API key.  Set `AI_ENABLED=true` and supply
  `AI_OPENAI_API_KEY` if you want it back; you'll also need to add
  the AI service binary to the Dockerfile.
- **`appflowy_search`** (Tantivy keyword search) — adds a 4th Rust
  process.  AppFlowy works without it; full-text search won't.
- **`appflowy_worker`** (background jobs: import/export, mailers) —
  imports from Notion / Markdown won't work.  Add this back if you
  ever need bulk import.
- **`appflowy_web`** Bun-based SSR layer — replaced with the
  pre-built static SPA bundle from the same image.  SEO-friendly
  published-page rendering is gone, but for a single-tenant
  workspace nobody links from search engines anyway.
- **`admin_frontend`** — the Super Admin panel.  GoTrue has a
  built-in admin user; for routine workspace use it isn't needed.
- **SMTP** — magic-link / password-reset emails are disabled
  (`GOTRUE_MAILER_AUTOCONFIRM=true`).  The owner signs in through
  the OIDC bridge, not via password reset, so there's nothing to
  email.

## SSO flow

1. Owner navigates to `https://appflowy.<zone>/`.
2. nginx sees `X-OpenHost-Is-Owner: true`, no GoTrue session, and
   an `Accept: text/html` request → rewrites to `/sso-bounce`.
3. `sso_bounce.py` 302s to `/gotrue/authorize?provider=keycloak`.
4. GoTrue 302s to the OIDC bridge's
   `/realms/openhost/protocol/openid-connect/auth` (still on the
   same hostname, internally proxied to `oidc_bridge.py`).
5. The bridge sees `X-OpenHost-Is-Owner: true` and 302s back to
   GoTrue's `/gotrue/callback?code=...&state=...` with an
   authorization code.
6. GoTrue exchanges the code at the bridge's `/token`, validates
   the ID token's signature against `/jwks_uri`, and mints a
   GoTrue session JWT.
7. The browser lands on the SPA with a `sb-<project>-auth-token`
   in localStorage; subsequent /api/ and /ws calls authenticate
   with the GoTrue JWT.

## Files

| File              | Purpose                                                    |
| ----------------- | ---------------------------------------------------------- |
| `openhost.toml`   | OpenHost manifest                                          |
| `Dockerfile`      | Multi-stage: copies binaries from appflowy_cloud, gotrue, appflowy_web upstream images onto Ubuntu 24.04 |
| `start.sh`        | Boots all internal services in order; supervises via `wait -n` |
| `nginx.conf`      | Front-door router (proxies /api, /gotrue, /ws, /minio-api, etc.) |
| `oidc_bridge.py`  | OIDC IdP — both flat /_oidc/* and Keycloak-shape paths     |
| `sso_bounce.py`   | Owner SSO redirect helper                                   |
| `bootstrap.py`    | First-boot health checks (currently no-op)                  |

## Adding AI features later

If you want to re-enable AI:

1. Add `appflowy-ai-source` as a multi-stage source in the
   Dockerfile and copy `/app/main.py` plus the python venv it
   needs.
2. Update `start.sh` to launch the AI service on `127.0.0.1:5001`
   with the OpenAI key from a generated secret file (or pulled
   from the openhost-secrets-v2 service).
3. Set `AI_ENABLED=true` and `AI_SERVER_HOST=127.0.0.1` in the
   appflowy_cloud env block.
4. Bump `[resources] memory_mb` to 2048 — the AI service is a
   large Python process with embeddings models loaded.
