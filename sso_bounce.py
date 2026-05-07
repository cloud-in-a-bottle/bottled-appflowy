#!/usr/bin/env python3
"""SSO bouncer for openhost-appflowy.

GoTrue's keycloak provider is a standard OAuth2 redirect flow:

  1. Browser hits ``/gotrue/authorize?provider=keycloak`` (the
     supabase_js client's signInWithOAuth call).
  2. GoTrue 302s to the OIDC authorize endpoint with the right
     state and redirect_uri.
  3. The OIDC provider 302s back to ``/gotrue/callback``.
  4. GoTrue mints its own session JWT and 302s back to the SPA.

So unlike Lemmy (which expects a pre-baked localStorage state),
all the bouncer needs to do for owner-flow start is 302 to
``/gotrue/authorize?provider=keycloak`` with a redirect_to param
pointing at ``/`` on the AppFlowy SPA.  Anyone non-owner gets
sent to the zone /login.

Run as: ``uvicorn sso_bounce:app --host 127.0.0.1 --port 7100``
"""

from __future__ import annotations

import logging
import os
from urllib.parse import urlencode

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import RedirectResponse, Response
from starlette.routing import Route

logger = logging.getLogger("openhost-appflowy.bounce")

# Public hostname for this app, e.g. ``appflowy.<zone>``.  The
# bounce target ``/gotrue/authorize`` is on the same host; we just
# need the X-Forwarded-Host the OpenHost router provides.


def _is_owner(request: Request) -> bool:
    return request.headers.get("X-OpenHost-Is-Owner", "").lower() == "true"


def _bare_zone(request: Request) -> str:
    host = request.headers.get("X-Forwarded-Host", request.url.netloc)
    return host.split(".", 1)[1] if "." in host else host


async def bounce(request: Request) -> Response:
    if not _is_owner(request):
        return RedirectResponse(f"https://{_bare_zone(request)}/login", status_code=302)

    host = request.headers.get("X-Forwarded-Host", request.url.netloc)
    prev = request.query_params.get("prev", "/")
    if not prev.startswith("/"):
        prev = "/"

    redirect_to = f"https://{host}{prev}"
    qs = urlencode({
        "provider": "keycloak",
        "redirect_to": redirect_to,
    })
    target = f"https://{host}/gotrue/authorize?{qs}"
    return RedirectResponse(target, status_code=302)


routes = [Route("/sso-bounce", bounce)]

app: Starlette = Starlette(debug=False, routes=routes)
