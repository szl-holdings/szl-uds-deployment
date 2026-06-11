# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# a11oy SSO login proof — drive the REAL Keycloak OIDC Authorization Code flow
# in front of a11oy and prove two things that helm-render + a server-side
# dry-run can NEVER prove (the gap Task #417 closes):
#
#   1. PRIMARY — the login screen actually appears: an *unauthenticated* request
#      to a11oy (https://<a11oy host>/) is 302-redirected by the UDS authservice
#      to Keycloak's OIDC authorize endpoint on the public SSO host. Before this
#      proof, "behind Keycloak SSO" was only validated by `helm template
#      --set udsPackage.sso.enabled=true` + a Package CR dry-run, because
#      Keycloak does not fit the 2-vCPU uds-szl-demo box (scaled 0/0).
#
#   2. FULL FLOW — after logging in at Keycloak, the authservice forwards the
#      now-authenticated browser back to a11oy and a11oy serves a 200. This
#      walks the complete Authorization Code dance with a cookie-jar session:
#        unauth GET -> 302 Keycloak authorize -> login form -> POST creds
#        -> 302 callback (?code=) -> authservice session cookie -> 200 a11oy.
#
# This script talks to the cluster's gateways purely over HTTPS using the public
# hostnames; the caller (the workflow) maps those hostnames to the live Istio
# gateway IPs in /etc/hosts, so no in-cluster knowledge leaks in here. TLS is the
# cluster's self-signed dev cert, so verification is intentionally disabled.
#
# Every assertion is FAIL-LOUD: any deviation exits non-zero with diagnostics so
# a regression that quietly drops the SSO gate (e.g. an empty `sso: []`, a wrong
# authservice selector, or a broken redirectUri) turns red here instead of
# silently shipping an unprotected a11oy.

import html
import os
import re
import sys
import urllib.parse

try:
    import requests
    from requests.packages.urllib3.exceptions import InsecureRequestWarning  # type: ignore
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)  # type: ignore
except Exception as exc:  # pragma: no cover - import guard
    print(f"FATAL: the 'requests' package is required: {exc}", file=sys.stderr)
    sys.exit(2)


def env(name, default=None, required=False):
    val = os.environ.get(name, default)
    if required and not val:
        print(f"FATAL: required environment variable {name} is unset", file=sys.stderr)
        sys.exit(2)
    return val


A11OY_HOST = env("A11OY_HOST", required=True)            # e.g. a11oy.admin.uds.dev
KC_ADMIN_BASE = env("KC_ADMIN_BASE", required=True).rstrip("/")  # https://keycloak.admin.uds.dev
KC_PUBLIC_HOST = env("KC_PUBLIC_HOST", required=True)    # e.g. sso.uds.dev
KC_ADMIN_USER = env("KC_ADMIN_USER", "admin")
KC_ADMIN_PASSWORD = env("KC_ADMIN_PASSWORD", required=True)
REALM = env("REALM", "uds")
TEST_USER = env("TEST_USER", "sso-proof-user")
TEST_PASSWORD = env("TEST_PASSWORD", required=True)

A11OY_URL = f"https://{A11OY_HOST}/"
TIMEOUT = 30


def fail(msg, extra=None):
    print(f"::error::{msg}")
    print(f"FATAL: {msg}", file=sys.stderr)
    if extra:
        print(extra, file=sys.stderr)
    sys.exit(1)


def admin_token():
    """Master-realm admin token via the admin-cli direct-grant client."""
    url = f"{KC_ADMIN_BASE}/realms/master/protocol/openid-connect/token"
    resp = requests.post(
        url,
        data={
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": KC_ADMIN_USER,
            "password": KC_ADMIN_PASSWORD,
        },
        verify=False,
        timeout=TIMEOUT,
    )
    if resp.status_code != 200:
        fail(
            "could not obtain a Keycloak master-realm admin token "
            f"(HTTP {resp.status_code}) — check the admin secret/host",
            resp.text[:500],
        )
    tok = resp.json().get("access_token")
    if not tok:
        fail("admin token response had no access_token", resp.text[:500])
    print("OK: obtained Keycloak master-realm admin token.")
    return tok


def ensure_test_user(token):
    """Create (or reset) an enabled, fully-profiled test user in the SSO realm.

    emailVerified + no required actions + a full profile avoids Keycloak's
    update-profile / verify-email interstitials so the headless login completes
    in one POST.
    """
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    base = f"{KC_ADMIN_BASE}/admin/realms/{REALM}/users"
    payload = {
        "username": TEST_USER,
        "enabled": True,
        "emailVerified": True,
        "email": f"{TEST_USER}@example.com",
        "firstName": "SSO",
        "lastName": "Proof",
        "requiredActions": [],
        "credentials": [
            {"type": "password", "value": TEST_PASSWORD, "temporary": False}
        ],
    }
    resp = requests.post(base, json=payload, headers=headers, verify=False, timeout=TIMEOUT)
    if resp.status_code in (201, 204):
        print(f"OK: created SSO realm test user '{TEST_USER}' in realm '{REALM}'.")
        return
    if resp.status_code != 409:
        fail(
            f"could not create test user (HTTP {resp.status_code}) in realm '{REALM}'",
            resp.text[:500],
        )
    # 409 — already exists: locate it and force-reset password + profile.
    find = requests.get(
        base, params={"username": TEST_USER, "exact": "true"},
        headers=headers, verify=False, timeout=TIMEOUT,
    )
    users = find.json() if find.status_code == 200 else []
    if not users:
        fail("test user reported as existing (409) but could not be found")
    uid = users[0]["id"]
    upd = {
        "enabled": True,
        "emailVerified": True,
        "requiredActions": [],
    }
    requests.put(f"{base}/{uid}", json=upd, headers=headers, verify=False, timeout=TIMEOUT)
    pwd = {"type": "password", "value": TEST_PASSWORD, "temporary": False}
    rp = requests.put(
        f"{base}/{uid}/reset-password", json=pwd,
        headers=headers, verify=False, timeout=TIMEOUT,
    )
    if rp.status_code not in (200, 204):
        fail(f"could not reset test-user password (HTTP {rp.status_code})", rp.text[:300])
    print(f"OK: reused + reset existing SSO realm test user '{TEST_USER}'.")


def prove_login_screen_appears(session):
    """PRIMARY proof: unauthenticated a11oy request 302s to Keycloak."""
    r = session.get(A11OY_URL, allow_redirects=False, verify=False, timeout=TIMEOUT)
    if r.status_code not in (302, 303, 307, 308):
        fail(
            "unauthenticated request to a11oy was NOT redirected — SSO gate is "
            f"absent (got HTTP {r.status_code}, expected a 30x to Keycloak). "
            "This is exactly the 'empty sso:[] / authservice not selected' "
            "regression the proof guards against.",
            f"body: {r.text[:400]}",
        )
    loc = r.headers.get("Location", "")
    parsed = urllib.parse.urlparse(loc)
    if parsed.netloc != KC_PUBLIC_HOST or "openid-connect/auth" not in parsed.path:
        fail(
            "unauthenticated request redirected, but NOT to the Keycloak OIDC "
            f"authorize endpoint on {KC_PUBLIC_HOST} (Location={loc!r})",
        )
    print(
        "OK [PRIMARY]: unauthenticated a11oy request was 302-redirected to the "
        f"Keycloak login at https://{KC_PUBLIC_HOST}{parsed.path} — the SSO "
        "login screen genuinely appears in front of a11oy."
    )
    return loc


_FORM_ACTION_RE = re.compile(
    r'<form[^>]*\baction="([^"]*login-actions/authenticate[^"]*)"', re.IGNORECASE
)


def complete_login(session, authorize_url):
    """FULL flow: load the Keycloak login form, POST creds, land back on a11oy."""
    page = session.get(authorize_url, allow_redirects=True, verify=False, timeout=TIMEOUT)
    if page.status_code != 200 or urllib.parse.urlparse(page.url).netloc != KC_PUBLIC_HOST:
        fail(
            "could not load the Keycloak login page "
            f"(HTTP {page.status_code}, url={page.url})",
            page.text[:400],
        )
    m = _FORM_ACTION_RE.search(page.text)
    if not m:
        fail(
            "Keycloak login page had no recognisable username/password form — "
            "the realm may demand a different first factor.",
            page.text[:600],
        )
    action = html.unescape(m.group(1))
    resp = session.post(
        action,
        data={"username": TEST_USER, "password": TEST_PASSWORD, "credentialId": ""},
        allow_redirects=True,
        verify=False,
        timeout=TIMEOUT,
    )
    final_host = urllib.parse.urlparse(resp.url).netloc
    if resp.status_code != 200 or final_host != A11OY_HOST:
        hops = " -> ".join(h.headers.get("Location", h.url) for h in resp.history) or "(none)"
        fail(
            "login did not land back on a11oy with HTTP 200 "
            f"(final status {resp.status_code}, host {final_host}). "
            "Either the credentials were rejected or the authservice callback "
            "did not forward back to a11oy.",
            f"redirect chain: {hops}\nbody: {resp.text[:400]}",
        )
    # Sanity: we are on a11oy, not a Keycloak error page rendered under a11oy host.
    if "keycloak" in resp.text.lower() and "error" in resp.text.lower():
        fail("landed on a11oy host but the body looks like a Keycloak error page", resp.text[:400])
    print(
        "OK [FULL FLOW]: authenticated at Keycloak and the authservice forwarded "
        f"the browser back to https://{A11OY_HOST}/ with HTTP 200 — the complete "
        "SSO login flow works end-to-end."
    )


def main():
    token = admin_token()
    ensure_test_user(token)
    session = requests.Session()
    authorize_url = prove_login_screen_appears(session)
    complete_login(session, authorize_url)
    print("\nPROVEN: a11oy's Keycloak SSO login screen appears for unauthenticated "
          "users AND a real login completes back to a11oy.")


if __name__ == "__main__":
    main()
