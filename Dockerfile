# Placeholder image for openhost-appflowy.
#
# AppFlowy Cloud is a 7+ service stack: postgres, gotrue (Supabase
# auth), appflowy-cloud, appflowy-history, appflowy-worker, nginx,
# minio (S3-compatible blob store), and redis.  Bundling all of
# them into a single OpenHost container is non-trivial:
#
#   * GoTrue's OIDC client config has to be wired through env vars
#     AND the postgres-stored auth schema, so a Pattern D OIDC
#     bridge needs both an HTTP shim and a SQL bootstrap step.
#   * Minio needs to be reachable over loopback under a stable URL
#     for appflowy-cloud's signed-URL generation.
#   * appflowy-cloud expects a specific Postgres migration history
#     populated by its own migration runner; a clean first-boot
#     flow would need ~5 minutes of orchestration work alone.
#
# Until the upstream maintainers publish a single-image variant or
# until we have time for a full Pattern D + nginx-routed multi-
# service container, this image serves a static placeholder page.
# Replace this Dockerfile with a real implementation modelled on
# openhost-lemmy (which similarly bundles postgres + redis + nginx
# + an OIDC bridge in one container) when the work can be scheduled.

FROM docker.io/library/alpine:3.20

RUN apk add --no-cache \
        busybox-extras \
        tini \
 && mkdir -p /var/www \
 && cat > /var/www/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>OpenHost AppFlowy — placeholder</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif;
           max-width:48em; margin:3em auto; padding:0 1em;
           color:#222; line-height:1.5; }
    h1 { color:#3b82f6; }
    code { background:#f4f4f4; padding:0.1em 0.3em;
           border-radius:3px; }
    .note { background:#fef3c7; border-left:4px solid #f59e0b;
            padding:1em; margin:1.5em 0; }
  </style>
</head>
<body>
  <h1>AppFlowy: not yet shipped</h1>
  <div class="note">
    <strong>This is a placeholder.</strong>  The
    <code>openhost-appflowy</code> repo currently ships a static
    "coming soon" page.
  </div>
  <p>
    AppFlowy Cloud is a multi-service deployment requiring
    PostgreSQL, GoTrue (Supabase's auth service), the AppFlowy
    backend, AppFlowy History, AppFlowy Worker, MinIO (S3-
    compatible blob store), Redis, and an Nginx routing layer.
    Bundling those into a single OpenHost container is non-trivial
    and requires careful first-boot orchestration of GoTrue's
    OIDC client config (so the OpenHost zone owner can sign in
    via Pattern D) plus the AppFlowy Cloud migration runner.
  </p>
  <p>
    See the repo <a
    href="https://github.com/imbue-openhost/openhost-appflowy">
    README</a> for the design notes on how a full implementation
    would be wired together — modelled on
    <a href="https://github.com/imbue-openhost/openhost-lemmy">
    openhost-lemmy</a> which similarly bundles Postgres + Redis +
    Nginx + an OIDC bridge in one container.
  </p>
  <p>
    Tracker: pull requests welcome.
  </p>
</body>
</html>
HTML

# busybox httpd serves /var/www on the configured port.
EXPOSE 8080
ENTRYPOINT ["/sbin/tini", "--", "/usr/sbin/httpd", "-f", "-p", "0.0.0.0:8080", "-h", "/var/www"]
