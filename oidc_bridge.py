#!/usr/bin/env python3
"""OIDC bridge for openhost-appflowy.

GoTrue (the Supabase auth service AppFlowy uses) does NOT support
generic OIDC providers — it has a hardcoded list of
"external_<name>" provider implementations (apple, github, google,
keycloak, etc).  Of those, **keycloak** is the only one that's
parameterised: ``GOTRUE_EXTERNAL_KEYCLOAK_URL`` lets you point at
any OIDC issuer that exposes Keycloak-shaped paths.

So this bridge serves both flat OIDC paths AND Keycloak-style
``/realms/<realm>/protocol/openid-connect/...`` paths, all backed
by the same handlers.  The realm name is fixed to ``openhost``;
GoTrue is configured with ``EXTERNAL_KEYCLOAK_URL = <PUBLIC_BASE>/realms/openhost``.

Authentication source: the ``X-OpenHost-Is-Owner: true`` header
stamped by the OpenHost router.  If present, the OpenHost owner is
the authenticated subject; otherwise the bridge refuses.

Persistent state lives under ``$OIDC_DATA_DIR``:
  * signing-key.pem — RSA private key for ID-token signing.

Authorization-code store is in-memory (single-use, 5 min TTL).
"""

from __future__ import annotations

import base64
import logging
import os
import secrets
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, unquote_plus

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from starlette.applications import Starlette
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import HTMLResponse  # noqa: F401  -- imported for completeness
from starlette.responses import JSONResponse
from starlette.responses import PlainTextResponse
from starlette.responses import RedirectResponse
from starlette.responses import Response
from starlette.routing import Route

logger = logging.getLogger("openhost-appflowy.oidc")

# --- config -----------------------------------------------------------

DATA_DIR = Path(os.environ.get("OIDC_DATA_DIR", "/data/app_data/appflowy/oidc"))
PUBLIC_BASE = os.environ["OIDC_PUBLIC_BASE"].rstrip("/")
CLIENT_ID = os.environ["OIDC_CLIENT_ID"]
CLIENT_SECRET = os.environ["OIDC_CLIENT_SECRET"]
# GoTrue uses Keycloak-shape paths.  The "issuer" claim must match
# what GoTrue expects from the OIDC discovery doc, which is
# ``<EXTERNAL_KEYCLOAK_URL>``.
ISSUER = f"{PUBLIC_BASE}/realms/openhost"

OWNER_EMAIL_DEFAULT = os.environ.get(
    "OIDC_OWNER_EMAIL",
    f"owner@{os.environ.get('OPENHOST_ZONE_DOMAIN', 'openhost.local')}",
)
ID_TOKEN_TTL_SECONDS = 60 * 60
ACCESS_TOKEN_TTL_SECONDS = 60 * 60
AUTH_CODE_TTL_SECONDS = 5 * 60

# --- key bootstrap ----------------------------------------------------

KEY_PATH = DATA_DIR / "signing-key.pem"


def _load_or_create_key() -> rsa.RSAPrivateKey:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if KEY_PATH.exists():
        with KEY_PATH.open("rb") as f:
            return serialization.load_pem_private_key(f.read(), password=None)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    KEY_PATH.write_bytes(pem)
    KEY_PATH.chmod(0o600)
    logger.info("Generated new OIDC signing key at %s", KEY_PATH)
    return key


_SIGNING_KEY = _load_or_create_key()
_KEY_ID = "openhost-appflowy-1"


def _public_jwk() -> dict[str, str]:
    public_numbers = _SIGNING_KEY.public_key().public_numbers()

    def _b64(n: int) -> str:
        byte_len = (n.bit_length() + 7) // 8
        return base64.urlsafe_b64encode(n.to_bytes(byte_len, "big")).rstrip(b"=").decode("ascii")

    return {
        "kty": "RSA",
        "alg": "RS256",
        "use": "sig",
        "kid": _KEY_ID,
        "n": _b64(public_numbers.n),
        "e": _b64(public_numbers.e),
    }


# --- in-memory authorization-code store ------------------------------

_auth_codes: dict[str, dict[str, Any]] = {}


def _gc_expired_codes() -> None:
    now = time.time()
    for code in [c for c, v in _auth_codes.items() if v["expires_at"] <= now]:
        _auth_codes.pop(code, None)


# --- helpers ---------------------------------------------------------


def _is_owner(request: Request) -> bool:
    return request.headers.get("X-OpenHost-Is-Owner", "").lower() == "true"


# --- handlers --------------------------------------------------------


async def discovery(_: Request) -> JSONResponse:
    """Keycloak-shape OpenID Connect discovery document.

    GoTrue's external_keycloak fetcher hits
    ``<EXTERNAL_KEYCLOAK_URL>/.well-known/openid-configuration`` and
    expects:

      - ``issuer`` matches the URL it requested from
      - ``authorization_endpoint`` / ``token_endpoint`` /
        ``userinfo_endpoint`` / ``jwks_uri`` URLs that it can reach.

    Both flat paths (/_oidc/*) and Keycloak-shape paths
    (/realms/openhost/protocol/openid-connect/*) are exposed; we
    advertise the Keycloak-shape ones in discovery because that's
    what GoTrue would natively expect from a real Keycloak.
    """
    return JSONResponse({
        "issuer": ISSUER,
        "authorization_endpoint": f"{ISSUER}/protocol/openid-connect/auth",
        "token_endpoint": f"{ISSUER}/protocol/openid-connect/token",
        "userinfo_endpoint": f"{ISSUER}/protocol/openid-connect/userinfo",
        "jwks_uri": f"{ISSUER}/protocol/openid-connect/certs",
        "end_session_endpoint": f"{ISSUER}/protocol/openid-connect/logout",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": ["RS256"],
        "scopes_supported": ["openid", "email", "profile"],
        "token_endpoint_auth_methods_supported": ["client_secret_post", "client_secret_basic"],
        "claims_supported": ["sub", "email", "email_verified", "name", "preferred_username"],
        "code_challenge_methods_supported": ["S256"],
    })


async def jwks(_: Request) -> JSONResponse:
    return JSONResponse({"keys": [_public_jwk()]})


async def authorize(request: Request) -> Response:
    """Authorization endpoint.  If ``X-OpenHost-Is-Owner: true``,
    issue an authorization code immediately and 302 to the supplied
    redirect_uri.  Otherwise 302 to the zone /login.
    """
    params = request.query_params
    response_type = params.get("response_type", "")
    client_id = params.get("client_id", "")
    redirect_uri = params.get("redirect_uri", "")
    state = params.get("state", "")
    nonce = params.get("nonce")
    scope = params.get("scope", "openid")
    code_challenge = params.get("code_challenge")
    code_challenge_method = params.get("code_challenge_method")

    if response_type != "code":
        raise HTTPException(400, "only response_type=code is supported")
    if client_id != CLIENT_ID:
        raise HTTPException(400, f"unknown client_id (expected {CLIENT_ID!r}, got {client_id!r})")
    if not redirect_uri:
        raise HTTPException(400, "missing redirect_uri")

    if not _is_owner(request):
        zone = request.headers.get("X-Forwarded-Host", request.url.netloc)
        bare_zone = zone.split(".", 1)[1] if "." in zone else zone
        login_url = f"https://{bare_zone}/login"
        return RedirectResponse(login_url, status_code=302)

    code = secrets.token_urlsafe(32)
    _gc_expired_codes()
    _auth_codes[code] = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "nonce": nonce,
        "scope": scope,
        "code_challenge": code_challenge,
        "code_challenge_method": code_challenge_method,
        "email": OWNER_EMAIL_DEFAULT,
        "expires_at": time.time() + AUTH_CODE_TTL_SECONDS,
    }

    qs = {"code": code}
    if state:
        qs["state"] = state
    sep = "&" if "?" in redirect_uri else "?"
    return RedirectResponse(redirect_uri + sep + urlencode(qs), status_code=302)


async def _read_form(request: Request) -> dict[str, str]:
    body = (await request.body()).decode("utf-8")
    out: dict[str, str] = {}
    for pair in body.split("&"):
        if not pair:
            continue
        k, _, v = pair.partition("=")
        out[unquote_plus(k)] = unquote_plus(v)
    return out


def _check_client_auth(request: Request, form: dict[str, str]) -> None:
    auth_header = request.headers.get("authorization", "")
    if auth_header.lower().startswith("basic "):
        try:
            decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise HTTPException(401, "invalid Basic auth header") from exc
        provided_id, _, provided_secret = decoded.partition(":")
    else:
        provided_id = form.get("client_id", "")
        provided_secret = form.get("client_secret", "")
    if not (provided_id == CLIENT_ID and secrets.compare_digest(provided_secret, CLIENT_SECRET)):
        raise HTTPException(401, "invalid client credentials")


def _verify_pkce(record: dict[str, Any], code_verifier: str | None) -> None:
    challenge = record.get("code_challenge")
    if not challenge:
        return
    if not code_verifier:
        raise HTTPException(400, "code_verifier required (PKCE was used at /authorize)")
    method = (record.get("code_challenge_method") or "").upper() or "PLAIN"
    if method == "S256":
        import hashlib
        expected = base64.urlsafe_b64encode(
            hashlib.sha256(code_verifier.encode("ascii")).digest()
        ).rstrip(b"=").decode("ascii")
        if not secrets.compare_digest(expected, challenge):
            raise HTTPException(400, "code_verifier mismatch (S256)")
    elif method == "PLAIN":
        if not secrets.compare_digest(code_verifier, challenge):
            raise HTTPException(400, "code_verifier mismatch (plain)")
    else:
        raise HTTPException(400, f"unsupported code_challenge_method {method}")


async def token(request: Request) -> JSONResponse:
    form = await _read_form(request)
    _check_client_auth(request, form)

    grant_type = form.get("grant_type", "")
    if grant_type == "authorization_code":
        code = form.get("code", "")
        if not code:
            raise HTTPException(400, "missing code")
        redirect_uri = form.get("redirect_uri", "")

        _gc_expired_codes()
        record = _auth_codes.pop(code, None)
        if record is None:
            raise HTTPException(400, "unknown or expired code")
        if record["redirect_uri"] != redirect_uri:
            raise HTTPException(400, "redirect_uri mismatch")

        _verify_pkce(record, form.get("code_verifier"))

        now = int(time.time())
        email = record["email"]
        sub = email
        id_token_claims = {
            "iss": ISSUER,
            "sub": sub,
            "aud": CLIENT_ID,
            "iat": now,
            "exp": now + ID_TOKEN_TTL_SECONDS,
            "email": email,
            "email_verified": True,
            "name": "owner",
            "preferred_username": "owner",
        }
        if record.get("nonce"):
            id_token_claims["nonce"] = record["nonce"]

        id_token = jwt.encode(
            id_token_claims,
            _SIGNING_KEY,
            algorithm="RS256",
            headers={"kid": _KEY_ID},
        )
        access_token = jwt.encode(
            {
                "iss": ISSUER,
                "sub": sub,
                "iat": now,
                "exp": now + ACCESS_TOKEN_TTL_SECONDS,
                "email": email,
                "scope": record.get("scope", "openid"),
                "token_type": "access",
            },
            _SIGNING_KEY,
            algorithm="RS256",
            headers={"kid": _KEY_ID},
        )
        # GoTrue's keycloak provider also wants a refresh_token field
        # (it persists it in the auth.identities row).  We mint a
        # token_urlsafe blob; it's not used by the bridge for
        # anything (no refresh-token rotation here), so a fresh one
        # per token call is fine.  GoTrue treats a refresh_token
        # call as opaque-string-out-of-the-blue and stores it.
        refresh_token = secrets.token_urlsafe(48)
        return JSONResponse({
            "access_token": access_token,
            "token_type": "Bearer",
            "expires_in": ACCESS_TOKEN_TTL_SECONDS,
            "id_token": id_token,
            "refresh_token": refresh_token,
            "scope": record.get("scope", "openid"),
        })

    if grant_type == "refresh_token":
        # GoTrue won't actually call this for keycloak (it manages
        # its own session JWTs after the initial /authorize dance),
        # but a real OIDC IdP must support it for spec-conformance.
        # Return a fresh access token with no upgrade in claims.
        now = int(time.time())
        access_token = jwt.encode(
            {
                "iss": ISSUER,
                "sub": OWNER_EMAIL_DEFAULT,
                "iat": now,
                "exp": now + ACCESS_TOKEN_TTL_SECONDS,
                "email": OWNER_EMAIL_DEFAULT,
                "scope": "openid",
                "token_type": "access",
            },
            _SIGNING_KEY,
            algorithm="RS256",
            headers={"kid": _KEY_ID},
        )
        return JSONResponse({
            "access_token": access_token,
            "token_type": "Bearer",
            "expires_in": ACCESS_TOKEN_TTL_SECONDS,
            "refresh_token": secrets.token_urlsafe(48),
            "scope": "openid",
        })

    raise HTTPException(400, f"unsupported grant_type {grant_type!r}")


def _verify_access_token(token_value: str) -> dict[str, Any]:
    try:
        return jwt.decode(
            token_value,
            _SIGNING_KEY.public_key(),
            algorithms=["RS256"],
            options={"require": ["sub", "exp"]},
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(401, f"invalid access token: {exc}") from exc


async def userinfo(request: Request) -> JSONResponse:
    auth_header = request.headers.get("authorization", "")
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(401, "missing Bearer token")
    claims = _verify_access_token(auth_header[7:])
    email = claims.get("email", "")
    return JSONResponse({
        "sub": claims["sub"],
        "email": email,
        "email_verified": True,
        "name": "owner",
        "preferred_username": "owner",
    })


async def healthz(_: Request) -> Response:
    return PlainTextResponse("ok\n")


async def http_exception_handler(request: Request, exc: HTTPException) -> Response:
    if request.url.path.startswith(("/_oidc/", "/realms/")):
        return JSONResponse(
            {"error": "invalid_request", "error_description": exc.detail},
            status_code=exc.status_code,
        )
    return PlainTextResponse(str(exc.detail) + "\n", status_code=exc.status_code)


# Routes — same handlers exposed under both flat /_oidc/* paths
# (for tooling / debugging) and Keycloak-shape paths (which is
# what GoTrue actually consumes).
routes = [
    Route("/_oidc/healthz", healthz),
    Route("/_oidc/.well-known/openid-configuration", discovery),
    Route("/_oidc/jwks", jwks),
    Route("/_oidc/authorize", authorize),
    Route("/_oidc/token", token, methods=["POST"]),
    Route("/_oidc/userinfo", userinfo, methods=["GET", "POST"]),
    # Keycloak-shape paths.  Realm name pinned to "openhost".
    Route("/realms/openhost/.well-known/openid-configuration", discovery),
    Route("/realms/openhost/protocol/openid-connect/certs", jwks),
    Route("/realms/openhost/protocol/openid-connect/auth", authorize),
    Route("/realms/openhost/protocol/openid-connect/token", token, methods=["POST"]),
    Route(
        "/realms/openhost/protocol/openid-connect/userinfo",
        userinfo,
        methods=["GET", "POST"],
    ),
]

app: Starlette = Starlette(
    debug=False,
    routes=routes,
    exception_handlers={HTTPException: http_exception_handler},
)
