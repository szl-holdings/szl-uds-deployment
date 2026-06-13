#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bump-receipts-version.sh — one-command, can't-drift version bump for szl-receipts.
#
# WHY THIS EXISTS
# ---------------
# The szl-receipts version is written in THREE places that must agree, or a fresh
# clone installs the wrong thing (and CI goes red via version-coherence-guard.yml
# + the image-digest / pin guards):
#
#   1. charts/szl-receipts/Chart.yaml   -> version AND appVersion
#   2. charts/szl-receipts/values.yaml  -> server.image.tag (uds-v<version>)
#                                          server.image.digest (the @sha256 pin)
#   3. packages/szl-receipts/zarf.yaml  -> the server image ref
#        ghcr.io/szl-holdings/szl-receipts-server:uds-v<version>@sha256:<digest>
#
# A previous half-finished bump left the chart on 0.4.0 while the image tag/zarf
# ref had already moved to uds-v0.4.1; the coherence guard only CATCHES that drift
# after the fact (red CI). This script PERFORMS the bump in lockstep so the whole
# class of failure cannot recur. Run it instead of hand-editing the files.
#
# The image.digest is updated in BOTH values.yaml and zarf.yaml so they stay
# byte-identical (image-pin-guard's chart-zarf-digest-match subcommand asserts
# this); use the linux/amd64 CHILD digest of the freshly published image, never
# the multi-arch index digest.
#
# USAGE
# -----
#   scripts/bump-receipts-version.sh <new-version> <new-digest>
#
#     <new-version>  semantic version like 0.4.2 (no leading 'v' / 'uds-v').
#     <new-digest>   the linux/amd64 child digest of the newly published
#                    ghcr.io/szl-holdings/szl-receipts-server:uds-v<new-version>
#                    image, with or without the 'sha256:' prefix, e.g.
#                    sha256:758052db...  or  758052db...
#
# Publishing the image is a SEPARATE step (push tag receipts-server-v<version> ->
# receipts-server-image.yml builds + cosign-signs ghcr .../szl-receipts-server:
# uds-v<version>). Resolve the published child digest, then run this script.
#
# After running, verify with:
#   bash <(...)  # nothing else needed — version-coherence-guard.yml passes,
#   git diff      # review, then commit.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

# ── Locate the repo root relative to this script (scripts/..) ─────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHART="$ROOT/charts/szl-receipts/Chart.yaml"
VALUES="$ROOT/charts/szl-receipts/values.yaml"
ZARF="$ROOT/packages/szl-receipts/zarf.yaml"

# ── Arguments ─────────────────────────────────────────────────────────────────
[ "$#" -eq 2 ] || die "usage: $(basename "$0") <new-version> <new-digest>
  e.g. $(basename "$0") 0.4.2 sha256:758052db66fd6257e4ac6b9834918df25dc819097beb387062b9e54e6cd8f0f4"

VERSION="$1"
DIGEST_ARG="$2"

# new-version: bare semver, no leading v/uds-v (those are derived).
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "new-version '$VERSION' must be a bare semver like 0.4.2 (no leading 'v' or 'uds-v')."

# new-digest: accept with or without sha256: prefix; require 64 lowercase hex.
HEX="${DIGEST_ARG#sha256:}"
echo "$HEX" | grep -qE '^[0-9a-f]{64}$' \
  || die "new-digest '$DIGEST_ARG' must be a sha256 digest (64 hex chars, optional 'sha256:' prefix)."

TAG="uds-v${VERSION}"
DIGEST="sha256:${HEX}"
REPO_IMG="ghcr.io/szl-holdings/szl-receipts-server"
REF="${REPO_IMG}:${TAG}@${DIGEST}"

for f in "$CHART" "$VALUES" "$ZARF"; do
  [ -f "$f" ] || die "missing required file: $f"
done

echo "Bumping szl-receipts -> version=${VERSION}, tag=${TAG}, digest=${DIGEST}"

# ── 1. Chart.yaml: version + appVersion (top-level scalars) ──────────────────
tmp="$(mktemp)"
sed -E \
  -e "s/^version:.*/version: ${VERSION}/" \
  -e "s/^appVersion:.*/appVersion: \"${VERSION}\"/" \
  "$CHART" > "$tmp" && mv "$tmp" "$CHART"

# ── 2. values.yaml: server.image.tag + server.image.digest ───────────────────
# Edit ONLY inside the top-level `server:` block's `image:` sub-block so the
# separate dashboard nginx `image:` (docker.io/library/nginx) is never touched.
# State machine mirrors version-coherence-guard.yml's reader; text-preserving
# (we never run a YAML re-serializer — these files are heavily commented).
tmp="$(mktemp)"
awk -v newtag="$TAG" -v newdigest="$DIGEST" '
{
  line=$0
  if (line ~ /^server:[[:space:]]*$/) { in_s=1; in_img=0; print; next }
  if (in_s && line ~ /^[^[:space:]#]/) { in_s=0; in_img=0 }   # left the server: block
  if (in_s) {
    if (line ~ /^[[:space:]]+image:[[:space:]]*$/) {
      match(line, /^[[:space:]]*/); img_indent=RLENGTH; in_img=1; print; next
    }
    if (in_img) {
      if (line ~ /^[[:space:]]*$/) { print; next }            # keep blank lines
      match(line, /^[[:space:]]*/); ind=RLENGTH
      if (ind <= img_indent) { in_img=0 }                     # dedented out of image:
      else {
        pad=substr(line, 1, RLENGTH)
        if (line ~ /^[[:space:]]+tag:/)    { print pad "tag: \"" newtag "\"";       tagdone=1; next }
        if (line ~ /^[[:space:]]+digest:/) { print pad "digest: \"" newdigest "\""; digdone=1; next }
      }
    }
  }
  print
}
END {
  if (!tagdone) { print "BUMP_ERR: server.image.tag not found" > "/dev/stderr"; exit 3 }
  if (!digdone) { print "BUMP_ERR: server.image.digest not found" > "/dev/stderr"; exit 3 }
}
' "$VALUES" > "$tmp" || die "failed to update $VALUES (server image tag/digest not found)"
mv "$tmp" "$VALUES"

# ── 3. zarf.yaml: the szl-receipts-server image ref (tag@digest) ─────────────
tmp="$(mktemp)"
sed -E \
  "s#(${REPO_IMG}:)[^@[:space:]]+@sha256:[0-9a-f]+#\1${TAG}@${DIGEST}#" \
  "$ZARF" > "$tmp" && mv "$tmp" "$ZARF"
grep -Fq "$REF" "$ZARF" || die "failed to update $ZARF — expected image ref not present after edit:
  $REF"

echo "OK. Updated:"
echo "  $CHART          (version + appVersion = ${VERSION})"
echo "  $VALUES   (server.image.tag = ${TAG}, digest = ${DIGEST})"
echo "  $ZARF (image ref = ${REF})"
echo
echo "Next: review 'git diff', then commit. version-coherence-guard.yml will pass with no manual edits."
