#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# sbom-sign-publish-receipts.sh
#
# RETIRED FLOW — DO NOT USE FOR RELEASES.
#   This script published the now-RETIRED internal artifact
#   `ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream` using an ephemeral
#   key-pair (private half gone). The authoritative artifact is the keyless package
#   `ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream`, built and signed keyless via
#   GitHub OIDC in CI (.github/workflows/zarf-package-sign.yml). Kept only as a
#   historical record of the original publish; see cosign/README.md for the
#   retirement decision.
#
# sbom-sign-publish-receipts.sh
#
# End-to-end supply-chain pipeline for the szl-receipts Zarf package:
#   1. Generate Syft SBOMs (SPDX + CycloneDX) for the receipts image.
#   2. Publish the (self-contained, image+SBOM-embedded) package to GHCR as OCI.
#   3. cosign-sign the published OCI artifact and the airgap tarball, then verify.
#   4. Pull the package back from the registry to prove the round-trip.
#
# Canonical production signing is keyless OIDC in CI (see .github/workflows/).
# This script's cosign signing uses a local key-pair for headless/box use; pass
# COSIGN_KEY/COSIGN_PUB to reuse an existing pair, otherwise an ephemeral pair is
# generated.
#
# Honesty: provenance is SLSA L1/L2 class (GitHub keyless attestation). No SLSA L3,
# Iron Bank, FedRAMP, or CMMC claims.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_DIR"

IMAGE="${IMAGE:-ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1}"
PKG="${PKG:-zarf-package-szl-receipts-amd64-0.3.1.tar.zst}"
OCI_REPO="${OCI_REPO:-oci://ghcr.io/szl-holdings/packages}"
OCI_REF="${OCI_REF:-ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream}"
export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"

echo "==> 1/4  Syft SBOMs for $IMAGE"
mkdir -p sbom
syft "registry:$IMAGE" \
  -o "spdx-json=sbom/szl-receipts-server-image.spdx.json" \
  -o "cyclonedx-json=sbom/szl-receipts-server-image.cdx.json"

echo "==> 2/4  Publish package to $OCI_REPO"
[ -f "$PKG" ] || { echo "ERROR: $PKG not found; run 'zarf package create packages/szl-receipts' first"; exit 1; }
zarf package publish "$PKG" "$OCI_REPO"

echo "==> 3/4  cosign sign + verify (OCI artifact and airgap tarball)"
if [ -z "${COSIGN_KEY:-}" ]; then
  COSIGN_KEY="$(mktemp -d)/cosign.key"; COSIGN_PUB="${COSIGN_KEY%.key}.pub"
  ( cd "$(dirname "$COSIGN_KEY")" && cosign generate-key-pair >/dev/null )
fi
cosign sign       --key "$COSIGN_KEY" --yes "$OCI_REF"
cosign verify     --key "$COSIGN_PUB"       "$OCI_REF"
cosign sign-blob  --key "$COSIGN_KEY" --yes --bundle "${PKG}.cosign.bundle" "$PKG"
cosign verify-blob --key "$COSIGN_PUB"      --bundle "${PKG}.cosign.bundle" "$PKG"

echo "==> 4/4  Pull package back from registry (round-trip)"
RT="$(mktemp -d)"
( cd "$RT" && zarf package pull "oci://$OCI_REF" )
zarf package inspect images "$RT"/*.tar.zst

echo "DONE. pubkey for verification:"
cat "$COSIGN_PUB"
