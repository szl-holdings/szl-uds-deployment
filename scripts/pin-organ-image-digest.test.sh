# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# pin-organ-image-digest.test.sh — negative-fixture self-test for the organ
# pin-drift check (scripts/pin-organ-image-digest.sh --check).
#
# WHY THIS EXISTS
# A drift check is only trustworthy if a STALE pin actually makes it FAIL. A check
# that passes vacuously (green while comparing nothing) would let a re-pushed organ
# tag silently diverge from the committed @sha256 pins forever. This test builds a
# synthetic mini-repo mirroring the real a11oy / killinchu deployment-file shapes,
# feeds the check a known "published" digest via the offline --digest override (no
# GHCR, no docker), and asserts:
#   * PASS when every pin matches the published digest;
#   * FAIL — naming the organ + tag + fix command — when ANY single pin is made
#     stale, in EACH place a pin lives (zarf images: ref, manifest image: ref,
#     and the chart image.digest scalar), for BOTH organs;
#   * FAIL (config error, rc 2) when an organ has no @sha256 pins at all.
#
# Pure text/offline — runs anywhere, no cluster, no registry.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${HERE}/pin-organ-image-digest.sh"

GOOD="sha256:1111111111111111111111111111111111111111111111111111111111111111"
STALE="sha256:2222222222222222222222222222222222222222222222222222222222222222"

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf 'ok: %s\n' "$*"; }
bad()  { printf '::error::SELF-TEST FAILED: %s\n' "$*"; fail=1; }

# build_fixture DIR DIGEST — write a mini-repo where every organ pin uses DIGEST.
build_fixture() {
  local root="$1" dig="$2"
  rm -rf "$root"
  mkdir -p "$root/packages/a11oy/manifests" \
           "$root/packages/killinchu/manifests" \
           "$root/charts/a11oy" "$root/charts/killinchu"

  # a11oy: zarf images: ref + manifest image: ref + chart image.digest scalar
  cat > "$root/packages/a11oy/zarf.yaml" <<EOF
kind: ZarfPackageConfig
components:
  - name: szl-a11oy-workload
    images:
      - ghcr.io/szl-holdings/a11oy:uds-v0.3.0@${dig}
EOF
  cat > "$root/packages/a11oy/manifests/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: a11oy
          image: ghcr.io/szl-holdings/a11oy:uds-v0.3.0@${dig}
EOF
  cat > "$root/charts/a11oy/values.yaml" <<EOF
image:
  repository: ghcr.io/szl-holdings/a11oy
  tag: "uds-v0.3.0"
  digest: "${dig}"
  pullPolicy: IfNotPresent
EOF

  # killinchu: zarf top-level image: ref + images: ref + manifest image: ref
  cat > "$root/packages/killinchu/zarf.yaml" <<EOF
kind: ZarfPackageConfig
metadata:
  image: "ghcr.io/szl-holdings/killinchu:uds-v0.2.0@${dig}"
components:
  - name: szl-killinchu-workload
    images:
      - ghcr.io/szl-holdings/killinchu:uds-v0.2.0@${dig}
EOF
  cat > "$root/packages/killinchu/manifests/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: killinchu
          image: ghcr.io/szl-holdings/killinchu:uds-v0.2.0@${dig}
EOF
  # killinchu chart is tag-only (no digest scalar), matching prod.
  cat > "$root/charts/killinchu/values.yaml" <<EOF
image:
  repository: ghcr.io/szl-holdings/killinchu
  tag: "uds-v0.2.0"
  pullPolicy: IfNotPresent
EOF
}

run_check() { # ORGAN ROOT  -> stdout captured, returns check rc
  local organ="$1" root="$2"
  bash "$SCRIPT" --organ "$organ" --root "$root" --digest "$GOOD" --check 2>&1
}

# ── 1. pristine fixture PASSES for both organs ───────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
build_fixture "$TMP/clean" "$GOOD"
for o in a11oy killinchu; do
  if out="$(run_check "$o" "$TMP/clean")"; then
    ok "pristine ${o} fixture passes the drift check"
  else
    bad "pristine ${o} fixture should PASS but the check failed:"; printf '%s\n' "$out"
  fi
done
# both organs together (default) also passes
if out="$(bash "$SCRIPT" --root "$TMP/clean" --digest "$GOOD" --check 2>&1)"; then
  ok "pristine both-organ default check passes"
else
  bad "pristine both-organ default check should PASS:"; printf '%s\n' "$out"
fi

# ── 2. a stale pin in EACH location makes the check FAIL ──────────────────────
# (organ, relative file, sed target) — make ONE pin stale, expect FAIL.
assert_stale_fails() {
  local organ="$1" relfile="$2" desc="$3"
  build_fixture "$TMP/case" "$GOOD"
  # flip the FIRST good digest occurrence in the target file to the stale one
  sed -i "0,/${GOOD}/s//${STALE}/" "$TMP/case/${relfile}"
  local out rc
  out="$(run_check "$organ" "$TMP/case")"; rc=$?
  if [ "$rc" -ne 1 ]; then
    bad "stale ${desc} should FAIL with rc 1 but rc=${rc}:"; printf '%s\n' "$out"; return
  fi
  if ! printf '%s' "$out" | grep -q "STALE: ${organ} "; then
    bad "stale ${desc} did not print a 'STALE: ${organ} ...' summary line:"; printf '%s\n' "$out"; return
  fi
  if ! printf '%s' "$out" | grep -qF "scripts/pin-organ-image-digest.sh --organ ${organ}"; then
    bad "stale ${desc} summary is missing the fix command:"; printf '%s\n' "$out"; return
  fi
  ok "stale ${desc} fails the check and names organ+tag+fix"
}

assert_stale_fails a11oy     "packages/a11oy/zarf.yaml"                 "a11oy zarf images: ref"
assert_stale_fails a11oy     "packages/a11oy/manifests/deployment.yaml" "a11oy manifest image: ref"
assert_stale_fails a11oy     "charts/a11oy/values.yaml"                 "a11oy chart image.digest scalar"
assert_stale_fails killinchu "packages/killinchu/zarf.yaml"            "killinchu zarf ref"
assert_stale_fails killinchu "packages/killinchu/manifests/deployment.yaml" "killinchu manifest image: ref"

# ── 3. an organ with NO @sha256 pins is a config error (rc 2), not a vacuous pass
build_fixture "$TMP/nopins" "$GOOD"
# strip every digest from a11oy, leaving tag-only refs/scalar
find "$TMP/nopins/packages/a11oy" "$TMP/nopins/charts/a11oy" -type f -print0 \
  | xargs -0 sed -i -E 's/@sha256:[0-9a-f]{64}//g; s/digest: "sha256:[0-9a-f]{64}"/digest: ""/g'
out="$(run_check a11oy "$TMP/nopins")"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "an organ with no @sha256 pins is reported as a config error (rc 2)"
else
  bad "no-pins a11oy should be rc 2 (config error) but rc=${rc}:"; printf '%s\n' "$out"
fi

# ── verdict ──────────────────────────────────────────────────────────────────
if [ "$fail" -ne 0 ]; then
  note "SELF-TEST FAILED — the organ pin-drift check is not catching stale pins."
  exit 1
fi
note "SELF-TEST PASSED — stale organ pins fail the drift check (negative fixtures hold)."
