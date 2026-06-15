# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# probe-organ-image-present.test.sh — offline negative-fixture self-test for
# scripts/probe-organ-image-present.sh.
#
# WHY THIS EXISTS
# The probe's whole job is to FAIL LOUDLY (and with a distinct, greppable verdict)
# when a retired organ's image or cosign signature disappears. If a future edit
# broke that — a swallowed exit code, a verdict that no longer says "IMAGE
# MISSING", the probe passing when the registry returns 404 — it could go green
# while protecting nothing. This test sources the probe, overrides ghcr_status()
# so NO network is touched, builds a synthetic mini-repo with a known digest pin,
# and asserts:
#   * both image + sig present  -> rc 0, "OK:" verdict
#   * image 404 / 401 / 403     -> rc 1, "IMAGE MISSING / PRIVATE" verdict
#   * image present, sig 404     -> rc 1, "SIGNATURE MISSING" verdict
#   * unreachable (000)          -> rc 1 (loud-not-silent)
#   * a missing pin file         -> rc 1
# Pure offline — no GHCR, no docker, no jq.
#
# Usage: bash scripts/probe-organ-image-present.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/probe-organ-image-present.sh"

# shellcheck source=/dev/null
source "$PROBE"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Known fake digest used by every fixture.
FAKE_HEX="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FAKE_DIGEST="sha256:${FAKE_HEX}"

# Build a synthetic repo root with a zarf.yaml carrying the fake pin for <organ>.
new_fixture() {
  local organ="$1"
  local dir; dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  mkdir -p "$dir/packages/$organ"
  cat > "$dir/packages/$organ/zarf.yaml" <<YAML
kind: ZarfPackageConfig
metadata:
  name: szl-$organ
  image: "ghcr.io/szl-holdings/$organ:uds-v0.2.0@${FAKE_DIGEST}"
components:
  - name: szl-$organ-workload
    images:
      - ghcr.io/szl-holdings/$organ:uds-v0.2.0@${FAKE_DIGEST}
YAML
  printf '%s' "$dir"
}

# Offline ghcr_status override. Returns codes from the test-controlled map
# STUB_IMAGE_CODE / STUB_SIG_CODE based on whether the reference is the digest
# (image manifest) or the .sig tag (cosign signature).
STUB_IMAGE_CODE="200"
STUB_SIG_CODE="200"
ghcr_status() {
  local reference="$2"
  case "$reference" in
    *.sig) printf '%s' "$STUB_SIG_CODE" ;;
    *)     printf '%s' "$STUB_IMAGE_CODE" ;;
  esac
}

run_case() {  # <name> <expect_rc> <expect_substr> <organ> <root>
  local name="$1" want_rc="$2" want_sub="$3" organ="$4" root="$5"
  local out rc
  out="$(probe_organ "$organ" "$root" 2>&1)"; rc=$?
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

D="$(new_fixture amaru)"

echo "== both present -> OK, rc 0 =="
STUB_IMAGE_CODE="200"; STUB_SIG_CODE="200"
run_case "present image+sig passes with OK verdict" 0 "OK: amaru image + cosign signature present" amaru "$D"

echo "== image gone (404) -> IMAGE MISSING, rc 1 =="
STUB_IMAGE_CODE="404"; STUB_SIG_CODE="200"
run_case "image 404 fails with IMAGE MISSING / PRIVATE" 1 "IMAGE MISSING / PRIVATE: amaru" amaru "$D"

echo "== image privatized (401) -> IMAGE MISSING, rc 1 =="
STUB_IMAGE_CODE="401"; STUB_SIG_CODE="200"
run_case "image 401 fails with IMAGE MISSING / PRIVATE" 1 "IMAGE MISSING / PRIVATE: amaru" amaru "$D"

echo "== image forbidden (403) -> IMAGE MISSING, rc 1 =="
STUB_IMAGE_CODE="403"; STUB_SIG_CODE="200"
run_case "image 403 fails with IMAGE MISSING / PRIVATE" 1 "IMAGE MISSING / PRIVATE: amaru" amaru "$D"

echo "== image present, sig gone (404) -> SIGNATURE MISSING, rc 1 =="
STUB_IMAGE_CODE="200"; STUB_SIG_CODE="404"
run_case "sig 404 fails with SIGNATURE MISSING" 1 "SIGNATURE MISSING: amaru" amaru "$D"

echo "== unreachable (000) -> loud, rc 1 =="
STUB_IMAGE_CODE="000"; STUB_SIG_CODE="200"
run_case "image 000 fails loud-not-silent" 1 "INCONCLUSIVE" amaru "$D"

echo "== missing pin file -> rc 1 =="
STUB_IMAGE_CODE="200"; STUB_SIG_CODE="200"
EMPTY="$(mktemp -d "$TMPROOT/empty.XXXXXX")"
run_case "missing zarf.yaml pin fails" 1 "" amaru "$EMPTY"

echo "== read_pin extracts the digest from a real-shaped zarf.yaml =="
got="$(read_pin amaru "$D")"
if [ "$got" = "$FAKE_DIGEST" ]; then
  echo "ok   read_pin returns the pinned digest"; PASS=$((PASS+1))
else
  echo "FAIL read_pin returned '$got' want '$FAKE_DIGEST'"; FAIL=$((FAIL+1))
fi

echo ""
echo "==================================================================="
echo "probe-organ-image-present self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
