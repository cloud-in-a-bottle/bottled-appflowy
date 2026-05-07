#!/usr/bin/env python3
"""First-boot bootstrap for openhost-appflowy.

Tasks (idempotent, run once per container start):

  1. Wait for GoTrue health.
  2. Wait for appflowy_cloud /api/health.
  3. (No-op for v1.)  GoTrue auto-creates the admin user from
     GOTRUE_ADMIN_EMAIL/PASSWORD on its first boot; once the OIDC
     keycloak provider is configured (which happens via env vars
     consumed by the gotrue process directly, not by an admin API
     call), AppFlowy's Supabase client picks it up via /gotrue/settings.
     There's no further server-side setup AppFlowy needs us to do.

This script exists for parity with openhost-lemmy and as a place
to land any future runtime configuration (e.g. seeding a default
workspace).  Currently it just verifies that the stack is healthy
and exits 0.
"""

from __future__ import annotations

import os
import sys
import time
import urllib.error
import urllib.request


GOTRUE_BASE_URL = os.environ.get("GOTRUE_BASE_URL", "http://127.0.0.1:9999").rstrip("/")
APPFLOWY_BASE_URL = os.environ.get("APPFLOWY_INTERNAL_URL", "http://127.0.0.1:8000").rstrip("/")


def _wait_for(url: str, label: str, max_seconds: int = 180) -> bool:
    deadline = time.time() + max_seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    print(f"[bootstrap] {label} ready")
                    return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(2)
    print(f"[bootstrap] {label} not ready after {max_seconds}s; continuing", file=sys.stderr)
    return False


def main() -> int:
    print("[bootstrap] starting")
    _wait_for(f"{GOTRUE_BASE_URL}/health", "gotrue")
    _wait_for(f"{APPFLOWY_BASE_URL}/api/health", "appflowy_cloud")
    # Sanity-check OIDC discovery — useful in container logs to
    # confirm the bridge is reachable from the browser path.
    try:
        appflowy_public = os.environ.get("APPFLOWY_BASE_URL")
        if appflowy_public:
            with urllib.request.urlopen(
                f"{appflowy_public}/realms/openhost/.well-known/openid-configuration",
                timeout=5,
            ) as r:
                print(
                    f"[bootstrap] OIDC discovery (public) returned {r.status}"
                )
    except Exception as exc:  # noqa: BLE001
        print(f"[bootstrap] OIDC discovery (public) probe failed: {exc}")
    print("[bootstrap] done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
