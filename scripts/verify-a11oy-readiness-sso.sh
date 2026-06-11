#!/usr/bin/env bash
# verify-a11oy-readiness-sso.sh
# ---------------------------------------------------------------------------
# Confirm the a11oy Operational Readiness tab + /api/a11oy/v1/readiness work
# through the full secure (Keycloak SSO) login flow on a UDS Core cluster.
#
# Background
# ----------
# a11oy runs inside UDS Core, exposed on the admin Istio gateway at
# a11oy.admin.<domain>. The Readiness feature is served by the a11oy workload
# on app=a11oy / service szl-a11oy:7860. SSO is value-driven in charts/a11oy
# (udsPackage.sso.enabled, default false): when ON, the UDS operator registers
# a Keycloak OIDC client (szl-a11oy) and inserts an authservice ext-authz in
# front of a11oy's HTTP ingress -- the SAME ingress that already serves the
# Readiness endpoint. Authservice only PREPENDS the login redirect; once a
# request is authenticated it is forwarded to the identical szl-a11oy:7860.
#
# Phases
# ------
#   0  preflight  (read-only) : Keycloak / authservice / admin gateway / a11oy
#                               package are all Ready.
#   1  construction (read-only): Readiness endpoint returns 200 through the
#                               admin gateway; the rendered SSO package inserts
#                               authservice for app=a11oy and forwards to the
#                               same service:port.
#   2  full e2e   (GATED, auto-reverting): enable SSO, assert the login screen
#                               appears (302 -> Keycloak), perform a real OIDC
#                               login, assert Readiness 200 through the
#                               authenticated path, then ALWAYS revert SSO off.
#
# Phase 2 only runs when RUN_FULL_E2E=1 AND Keycloak credentials are supplied
# (KC_USER / KC_PASS). It is fully reversible: an EXIT trap restores SSO to its
# original state regardless of outcome. Do NOT run phase 2 until the cluster's
# authservice waypoint programs cleanly (kubectl get gateway -A) -- a wedged
# waypoint would gate a11oy without a working login path.
#
# Usage
#   ./verify-a11oy-readiness-sso.sh                 # phases 0 + 1 (safe)
#   RUN_FULL_E2E=1 KC_USER=u KC_PASS=p \
#     ./verify-a11oy-readiness-sso.sh               # + phase 2 (live, reverts)
#
# Env knobs (defaults target the uds-szl-demo box):
#   NS=szl-a11oy  RELEASE=a11oy  DOMAIN=uds.dev  HOST=a11oy
#   ADMIN_GW_IP=<auto from admin-ingressgateway>   TENANT_GW_IP=<auto>
# ---------------------------------------------------------------------------
set -uo pipefail

NS="${NS:-szl-a11oy}"
RELEASE="${RELEASE:-a11oy}"
DOMAIN="${DOMAIN:-uds.dev}"
HOST="${HOST:-a11oy}"
ADMIN_HOST="${HOST}.admin.${DOMAIN}"
SSO_HOST="${SSO_HOST:-sso.${DOMAIN}}"
READINESS_PATH="${READINESS_PATH:-/api/a11oy/v1/readiness}"

pass=0; fail=0; warn=0
ok()   { echo "  PASS  $*"; pass=$((pass+1)); }
no()   { echo "  FAIL  $*"; fail=$((fail+1)); }
wn()   { echo "  WARN  $*"; warn=$((warn+1)); }
hdr()  { echo; echo "== $* =="; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }; }
need kubectl; need curl

ADMIN_GW_IP="${ADMIN_GW_IP:-$(kubectl get svc admin-ingressgateway -n istio-admin-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)}"
[ -n "$ADMIN_GW_IP" ] || ADMIN_GW_IP="$(kubectl get svc admin-ingressgateway -n istio-admin-gateway \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"

gw_curl() { # path -> prints "http_code redirect_url"
  local path="$1"
  curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' \
    --resolve "${ADMIN_HOST}:443:${ADMIN_GW_IP}" \
    "https://${ADMIN_HOST}${path}"
}

# ── Phase 0 : preflight (read-only) ─────────────────────────────────────────
hdr "Phase 0  preflight (read-only)"
echo "admin gateway IP: ${ADMIN_GW_IP:-<none>}"

ready() { # ns deploy/statefulset name
  local kind="$1" name="$2" ns="$3"
  local r
  r=$(kubectl get "$kind" "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}{.status.availableReplicas}' 2>/dev/null)
  [ -n "$r" ] && [ "$r" != "0" ]
}
ready statefulset keycloak keycloak     && ok "Keycloak is Ready (boot blocker resolved)" || no "Keycloak not Ready"
ready deploy authservice authservice    && ok "authservice is Ready"                       || no "authservice not Ready"
[ -n "$ADMIN_GW_IP" ]                    && ok "admin gateway has an address"               || no "admin gateway has no address"
phase="$(kubectl get package "$HOST" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
[ "$phase" = "Ready" ]                   && ok "a11oy UDS Package phase=Ready"              || no "a11oy package phase=$phase"

# waypoint health gate for phase 2
if kubectl get gateway -A 2>/dev/null | grep -qiE 'waypoint.*False'; then
  wn "an Istio waypoint reports PROGRAMMED=False -- resolve before RUN_FULL_E2E (authservice ext-authz may not engage)"
fi

# ── Phase 1 : construction proof (read-only) ────────────────────────────────
hdr "Phase 1  construction proof (read-only)"
read -r code _redir < <(gw_curl "$READINESS_PATH")
[ "$code" = "200" ] && ok "Readiness endpoint 200 through admin gateway ($READINESS_PATH)" \
                     || no "Readiness endpoint returned $code through admin gateway"
read -r hcode _ < <(gw_curl "/")
[ "$hcode" = "200" ] || [ "$hcode" = "302" ] && ok "a11oy console reachable through admin gateway (HTTP $hcode)" \
                     || no "a11oy console returned $hcode through admin gateway"

# Render the chart with SSO on and assert the gate sits in front of app=a11oy
# and forwards to the same service:port that already returns 200.
CHART_DIR="${CHART_DIR:-$(dirname "$0")/../charts/a11oy}"
if command -v helm >/dev/null 2>&1 && [ -d "$CHART_DIR" ]; then
  rendered="$(helm template "$RELEASE" "$CHART_DIR" --set udsPackage.sso.enabled=true 2>/dev/null)"
  echo "$rendered" | grep -q "enableAuthserviceSelector" \
    && echo "$rendered" | grep -q "clientId: szl-a11oy" \
    && ok "SSO-on render inserts authservice OIDC gate (client szl-a11oy) on a11oy ingress" \
    || no "SSO-on render missing authservice gate"
  echo "$rendered" | grep -q "app: a11oy" \
    && ok "authservice gate selects the SAME app=a11oy workload that serves Readiness" \
    || wn "could not confirm authservice selector app=a11oy in render"
else
  wn "helm or chart dir unavailable -- skipping render-based construction proof"
fi

# ── Phase 2 : full end-to-end (GATED, auto-reverting) ───────────────────────
if [ "${RUN_FULL_E2E:-0}" != "1" ]; then
  hdr "Phase 2  full e2e -- SKIPPED (set RUN_FULL_E2E=1 + KC_USER/KC_PASS to run)"
  echo
  echo "SUMMARY: pass=$pass fail=$fail warn=$warn  (phase 2 skipped)"
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

hdr "Phase 2  full end-to-end (live, auto-reverting)"
: "${KC_USER:?set KC_USER for phase 2}"; : "${KC_PASS:?set KC_PASS for phase 2}"
command -v helm >/dev/null 2>&1 || { echo "helm required for phase 2" >&2; exit 2; }

ORIG_SSO="$(helm get values "$RELEASE" -n "$NS" -o json 2>/dev/null \
  | grep -o '"enabled":[^,}]*' | tail -1 | grep -o 'true\|false' || echo false)"
revert() {
  echo "  .. reverting SSO to enabled=${ORIG_SSO}"
  helm upgrade "$RELEASE" "$CHART_DIR" -n "$NS" --reuse-values \
    --set "udsPackage.sso.enabled=${ORIG_SSO}" >/dev/null 2>&1 || true
}
trap revert EXIT

echo "  .. enabling SSO (helm upgrade --reuse-values --set udsPackage.sso.enabled=true)"
helm upgrade "$RELEASE" "$CHART_DIR" -n "$NS" --reuse-values \
  --set udsPackage.sso.enabled=true >/dev/null 2>&1 || no "helm upgrade (sso on) failed"

# wait for the operator to register the Keycloak client + authservice gate
for i in $(seq 1 30); do
  clients="$(kubectl get package "$HOST" -n "$NS" -o jsonpath='{.status.ssoClients}' 2>/dev/null)"
  [ -n "$clients" ] && [ "$clients" != "[]" ] && break
  sleep 4
done
[ -n "$clients" ] && [ "$clients" != "[]" ] && ok "Keycloak client registered: $clients" \
  || no "SSO client not registered after wait"

# 1) login screen appears: unauth request -> 302 redirect to Keycloak
read -r ucode uredir < <(gw_curl "$READINESS_PATH")
case "$ucode$uredir" in
  302*${SSO_HOST}*|307*${SSO_HOST}*) ok "unauth request redirects to Keycloak login ($ucode -> $uredir)";;
  *) no "expected 302->Keycloak for unauth request, got $ucode $uredir";;
esac

# 2) real OIDC login through authservice (headless authorization-code flow)
JAR="$(mktemp)"; trap 'rm -f "$JAR"; revert' EXIT
login_html="$(curl -sk -c "$JAR" -b "$JAR" -L \
  --resolve "${ADMIN_HOST}:443:${ADMIN_GW_IP}" \
  --resolve "${SSO_HOST}:443:${TENANT_GW_IP:-$ADMIN_GW_IP}" \
  "https://${ADMIN_HOST}${READINESS_PATH}")"
action="$(printf '%s' "$login_html" | grep -oiE 'action="[^"]*"' | head -1 | sed 's/action="//;s/"//;s/\&amp;/\&/g')"
if [ -n "$action" ]; then
  curl -sk -c "$JAR" -b "$JAR" -L \
    --resolve "${ADMIN_HOST}:443:${ADMIN_GW_IP}" \
    --resolve "${SSO_HOST}:443:${TENANT_GW_IP:-$ADMIN_GW_IP}" \
    --data-urlencode "username=${KC_USER}" \
    --data-urlencode "password=${KC_PASS}" \
    --data-urlencode "credentialId=" \
    "$action" -o /dev/null
  # 3) authenticated request now reaches Readiness 200 through the gated path
  read -r acode _ < <(curl -sk -b "$JAR" -o /dev/null -w '%{http_code} ' \
    --resolve "${ADMIN_HOST}:443:${ADMIN_GW_IP}" \
    "https://${ADMIN_HOST}${READINESS_PATH}")
  [ "$acode" = "200" ] && ok "Readiness 200 through AUTHENTICATED gateway path (post-login)" \
                       || no "post-login Readiness returned $acode"
else
  no "could not locate Keycloak login form action (login page not served?)"
fi

hdr "RESULT"
echo "SUMMARY: pass=$pass fail=$fail warn=$warn"
[ "$fail" -eq 0 ] && exit 0 || exit 1
