# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# probe-bundle-anon-pullable.test.sh — offline negative-fixture self-test for
# scripts/probe-bundle-anon-pullable.sh.
#
# WHY THIS EXISTS
# The probe's whole job is to FAIL LOUDLY (with a distinct, greppable verdict)
# when the public install bundle — or its cosign signature / SBOM attestation —
# stops being anonymously pullable from GHCR. If a future edit broke that (a
# swallowed exit code, a verdict that no longer says "NOT ANON-PULLABLE", the
# probe passing on a 401/403/404) it could go green while protecting nothing.
# This test sources the probe, overrides anon_ghcr_status() and anon_ghcr_digest()
# so NO network is touched, and asserts:
#   * manifest + .sig + .att all 200  -> rc 0, "OK:" verdict
#   * manifest privatized (401/403)    -> rc 1, "BUNDLE NOT ANON-PULLABLE"
#   * manifest gone (404)              -> rc 1, "BUNDLE NOT ANON-PULLABLE"
#   * manifest ok, .sig privatized     -> rc 1, "SIGNATURE NOT ANON-PULLABLE"
#   * manifest ok, .att gone (404)     -> rc 1, "ATTESTATION NOT ANON-PULLABLE"
#   * unreachable (000)                -> rc 1 (loud-not-silent)
#   * digest header missing            -> rc 1 (loud-not-silent)
# Pure offline — no GHCR, no docker, no jq. This is the task's required negative
# fixture proving the check actually fails when given a private/404 ref.
#
# Usage: bash scripts/probe-bundle-anon-pullable.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/probe-bundle-anon-pullable.sh"

# shellcheck source=/dev/null
source "$PROBE"

PASS=0
FAIL=0

REPO="szl-holdings/szl-uds-bundle"
TAG="uds-v0.2.0"
FAKE_HEX="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
FAKE_DIGEST="sha256:${FAKE_HEX}"

# Offline overrides. STUB_*_CODE drive what each anonymous HEAD "returns" based on
# whether the reference is the bundle tag, the .sig tag, or the .att tag.
STUB_MANIFEST_CODE="200"
STUB_SIG_CODE="200"
STUB_ATT_CODE="200"
STUB_DIGEST="$FAKE_DIGEST"

anon_ghcr_status() {
  local reference="$2"
  case "$reference" in
    *.sig) printf '%s' "$STUB_SIG_CODE" ;;
    *.att) printf '%s' "$STUB_ATT_CODE" ;;
    *)     printf '%s' "$STUB_MANIFEST_CODE" ;;
  esac
}

anon_ghcr_digest() {
  printf '%s' "$STUB_DIGEST"
}

run_case() {  # <name> <expect_rc> <expect_substr>
  local name="$1" want_rc="$2" want_sub="$3"
  local out rc
  out="$(probe_ref "$REPO" "$TAG" 2>&1)"; rc=$?
  local ok=1
  [ "$rc" -eq "$want_rc" ] || ok=0
  if [ -n "$want_sub" ] && ! printf '%s' "$out" | grep -qF "$want_sub"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    echo "ok   $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name (rc=$rc want=$want_rc; expected substring: '$want_sub')"
    printf '%s\n' "$out" | sed 's/^/       | /'; FAIL=$((FAIL+1))
  fi
}

echo "== manifest + sig + att all anon-200 -> OK, rc 0 =="
STUB_MANIFEST_CODE="200"; STUB_SIG_CODE="200"; STUB_ATT_CODE="200"; STUB_DIGEST="$FAKE_DIGEST"
run_case "all three anon-pullable passes with OK verdict" 0 "OK: ghcr.io/${REPO}:${TAG} manifest + cosign .sig + SBOM .att all anonymously pullable"

echo "== bundle privatized (401) -> BUNDLE NOT ANON-PULLABLE, rc 1 =="
STUB_MANIFEST_CODE="401"; STUB_SIG_CODE="200"; STUB_ATT_CODE="200"
run_case "manifest 401 fails with BUNDLE NOT ANON-PULLABLE" 1 "BUNDLE NOT ANON-PULLABLE:"

echo "== bundle forbidden (403) -> BUNDLE NOT ANON-PULLABLE, rc 1 =="
STUB_MANIFEST_CODE="403"; STUB_SIG_CODE="200"; STUB_ATT_CODE="200"
run_case "manifest 403 fails with BUNDLE NOT ANON-PULLABLE" 1 "BUNDLE NOT ANON-PULLABLE:"

echo "== bundle gone (404) -> BUNDLE NOT ANON-PULLABLE, rc 1 =="
STUB_MANIFEST_CODE="404"; STUB_SIG_CODE="200"; STUB_ATT_CODE="200"
run_case "manifest 404 fails with BUNDLE NOT ANON-PULLABLE" 1 "BUNDLE NOT ANON-PULLABLE:"

echo "== signature privatized (403) -> SIGNATURE NOT ANON-PULLABLE, rc 1 =="
STUB_MANIFEST_CODE="200"; STUB_SIG_CODE="403"; STUB_ATT_CODE="200"
run_case "sig 403 fails with SIGNATURE NOT ANON-PULLABLE" 1 "SIGNATURE NOT ANON-PULLABLE:"

echo "== signature gone (404) -> SIGNATURE NOT ANON-PULLABLE, rc 1 =="
STUB_MANIFEST_CODE="200"; STUB_SIG_CODE="404"; STUB_ATT_CODE="200"
run_case "sig 404 fails with SIGNATURE NOT ANON-PULLABLE" 1 "SIGNATURE NOT ANON-PULLABLE:"

echo "== attestation gone (404) -> ATTESTATION NOT ANON-PULLABLE, rc 1 =="
STUB_MANIFEST_CODE="200"; STUB_SIG_CODE="200"; STUB_ATT_CODE="404"
run_case "att 404 fails with ATTESTATION NOT ANON-PULLABLE" 1 "ATTESTATION NOT ANON-PULLABLE:"

echo "== attestation privatized (401) -> ATTESTATION NOT ANON-PULLABLE, rc 1 =="
STUB_MANIFEST_CODE="200"; STUB_SIG_CODE="200"; STUB_ATT_CODE="401"
run_case "att 401 fails with ATTESTATION NOT ANON-PULLABLE" 1 "ATTESTATION NOT ANON-PULLABLE:"

echo "== unreachable manifest (000) -> loud, rc 1 =="
STUB_MANIFEST_CODE="000"; STUB_SIG_CODE="200"; STUB_ATT_CODE="200"
run_case "manifest 000 fails loud-not-silent" 1 "BUNDLE PROBE INCONCLUSIVE"

echo "== digest header missing -> loud, rc 1 =="
STUB_MANIFEST_CODE="200"; STUB_SIG_CODE="200"; STUB_ATT_CODE="200"; STUB_DIGEST=""
run_case "missing digest header fails loud-not-silent" 1 "could not resolve the manifest digest"
STUB_DIGEST="$FAKE_DIGEST"

echo "== both sig AND att gone -> BOTH verdicts, rc 1 =="
STUB_MANIFEST_CODE="200"; STUB_SIG_CODE="404"; STUB_ATT_CODE="404"
out="$(probe_ref "$REPO" "$TAG" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "SIGNATURE NOT ANON-PULLABLE:" && printf '%s' "$out" | grep -qF "ATTESTATION NOT ANON-PULLABLE:"; then
  echo "ok   both sig+att missing reports both verdicts"; PASS=$((PASS+1))
else
  echo "FAIL both sig+att missing (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       | /'; FAIL=$((FAIL+1))
fi

echo ""
echo "==================================================================="
echo "probe-bundle-anon-pullable self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
