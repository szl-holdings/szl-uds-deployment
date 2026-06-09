# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# pin-receipts-image-digest.sh — resolve the published szl-receipts-server image
# digest for a tag and pin it everywhere, so a rebuild never breaks the bundle
# build with a stale, hand-hunted digest again.
#
# WHY THIS EXISTS
# ---------------
# `docker buildx` used to publish szl-receipts-server as a multi-arch OCI *index*
# (a provenance/SBOM attestation child rode along under `unknown/unknown`). zarf
# refuses an index digest ("resolved to an OCI image index ... select a specific
# platform"), so the zarf `images:` lists had to be hand-pinned to the amd64
# CHILD digest. Every rebuild minted a new index and silently broke the build
# until someone manually re-resolved and re-pasted the child digest into two
# files. The publish workflow now builds a single-arch amd64 manifest (no
# attestation index), but this script still defensively handles an index so a
# re-pin is always ONE command, not manual digest hunting.
#
# WHAT IT PINS
# ------------
#   1. zarf.yaml                        images: ...szl-receipts-server:<tag>@sha256:<ZARF_DIGEST>
#   2. packages/szl-receipts/zarf.yaml  images: ...szl-receipts-server:<tag>@sha256:<ZARF_DIGEST>
#   3. charts/szl-receipts/values.yaml  server.image.digest: "sha256:<CHART_DIGEST>"
#
# ZARF_DIGEST  = the amd64 image manifest digest (the index's linux/amd64 child
#                when the tag is still an index, otherwise the manifest itself).
#                This is the platform-specific manifest zarf can consume.
# CHART_DIGEST = whatever the tag points at directly (the index digest when the
#                tag is an index, otherwise the same single manifest). The kubelet
#                resolves an index fine, so the chart pins the tag's own digest.
# For a single-arch build the two are identical; the split only matters for a
# legacy index image.
#
# Usage:
#   scripts/pin-receipts-image-digest.sh [--tag <tag>] [--check]
#
#   --tag <tag>   image tag to resolve (default: the tag already in zarf.yaml,
#                 e.g. uds-v0.4.0)
#   --check       do not edit files; exit non-zero if the pinned digests differ
#                 from the published image, printing the exact command to fix it.
#
# Requires: docker buildx (imagetools), jq. Pure registry inspection — no cluster.

set -euo pipefail

REPO_IMAGE="ghcr.io/szl-holdings/szl-receipts-server"
ROOT_ZARF="zarf.yaml"
PKG_ZARF="packages/szl-receipts/zarf.yaml"
CHART_VALUES="charts/szl-receipts/values.yaml"

TAG=""
CHECK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Run from the repo root so the relative paths above resolve regardless of cwd.
cd "$(dirname "$0")/.."

for f in "$ROOT_ZARF" "$PKG_ZARF" "$CHART_VALUES"; do
  test -f "$f" || { echo "::error file=$f::missing — cannot pin digest" >&2; exit 1; }
done

# Default the tag to whatever is already pinned in zarf.yaml.
if [ -z "$TAG" ]; then
  TAG="$(grep -oE "szl-receipts-server:[^@[:space:]]+" "$ROOT_ZARF" | head -n1 | cut -d: -f2)"
  test -n "$TAG" || { echo "::error::could not infer tag from $ROOT_ZARF; pass --tag" >&2; exit 1; }
fi

REF="${REPO_IMAGE}:${TAG}"
echo "Resolving published digests for ${REF}"

command -v jq >/dev/null 2>&1 || { echo "::error::jq is required" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "::error::docker (buildx imagetools) is required" >&2; exit 1; }

RAW="$(docker buildx imagetools inspect "$REF" --raw)"

# CHART_DIGEST = the digest the tag points at directly.
CHART_DIGEST="$(docker buildx imagetools inspect "$REF" --format '{{.Manifest.Digest}}')"
case "$CHART_DIGEST" in
  sha256:*) : ;;
  *) echo "::error::could not resolve tag digest for ${REF}" >&2; exit 1 ;;
esac

# ZARF_DIGEST = amd64 image manifest. If the tag is an index, pick the
# linux/amd64 child (ignoring the unknown/unknown attestation child); otherwise
# the tag already points at a single manifest.
if printf '%s' "$RAW" | jq -e '.manifests' >/dev/null 2>&1; then
  ZARF_DIGEST="$(printf '%s' "$RAW" | jq -r '
    .manifests[]
    | select(.platform.os == "linux" and .platform.architecture == "amd64")
    | .digest' | head -n1)"
  [ -n "$ZARF_DIGEST" ] && [ "$ZARF_DIGEST" != "null" ] \
    || { echo "::error::no linux/amd64 child manifest found in index ${REF}" >&2; exit 1; }
else
  ZARF_DIGEST="$CHART_DIGEST"
fi

echo "  zarf  (amd64 manifest): ${ZARF_DIGEST}"
echo "  chart (tag digest)    : ${CHART_DIGEST}"

# Rewrite the szl-receipts-server image ref (preserving tag) to the given digest.
pin_zarf() {
  local file="$1" digest="$2"
  sed -E -i \
    "s#(${REPO_IMAGE//\//\\/}:[^@[:space:]]+)@sha256:[0-9a-f]{64}#\1@${digest}#g" \
    "$file"
}

# Rewrite the server.image.digest scalar in the chart values block.
pin_chart() {
  local file="$1" digest="$2"
  sed -E -i \
    "s#(^[[:space:]]*digest:[[:space:]]*\")sha256:[0-9a-f]{64}(\".*szl-receipts-server.*)?#\1${digest}\2#" \
    "$file"
}

if [ "$CHECK" -eq 1 ]; then
  rc=0
  grep -qF "${REPO_IMAGE}:${TAG}@${ZARF_DIGEST}" "$ROOT_ZARF" || { echo "::warning file=${ROOT_ZARF}::stale receipts digest"; rc=1; }
  grep -qF "${REPO_IMAGE}:${TAG}@${ZARF_DIGEST}" "$PKG_ZARF"  || { echo "::warning file=${PKG_ZARF}::stale receipts digest"; rc=1; }
  grep -qF "digest: \"${CHART_DIGEST}\"" "$CHART_VALUES"      || { echo "::warning file=${CHART_VALUES}::stale receipts digest"; rc=1; }
  if [ "$rc" -ne 0 ]; then
    echo "::warning::receipts-server pins are out of date for ${REF}."
    echo "Run:  scripts/pin-receipts-image-digest.sh --tag ${TAG}"
  else
    echo "OK: all receipts-server pins match the published ${REF}."
  fi
  exit "$rc"
fi

pin_zarf "$ROOT_ZARF" "$ZARF_DIGEST"
pin_zarf "$PKG_ZARF" "$ZARF_DIGEST"
# Only touch the server.image digest (avoid the nginx digest two blocks down).
# The chart values file lists szl-receipts-server first, then nginx; the awk
# below rewrites only the digest inside the szl-receipts-server image block.
awk -v d="$CHART_DIGEST" '
  /repository:[[:space:]]*ghcr\.io\/szl-holdings\/szl-receipts-server/ { inblk=1 }
  inblk && /^[[:space:]]*digest:[[:space:]]*"sha256:[0-9a-f]+"/ {
    sub(/sha256:[0-9a-f]+/, d); inblk=0
  }
  { print }
' "$CHART_VALUES" > "${CHART_VALUES}.tmp" && mv "${CHART_VALUES}.tmp" "$CHART_VALUES"

echo "Pinned szl-receipts-server@${TAG}:"
echo "  ${ROOT_ZARF}, ${PKG_ZARF} -> ${ZARF_DIGEST}"
echo "  ${CHART_VALUES} -> ${CHART_DIGEST}"
