# SBOMs — szl-receipts

Software Bills of Materials for the SZL Receipts container image and Zarf package.
Reviewable in-tree; regenerable from the commands below.

## Files

| File | Tool | Format | Subject |
|------|------|--------|---------|
| `szl-receipts-server-image.spdx.json` | Syft v1.18.1 | SPDX 2.3 (JSON) | `ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1` (109 pkgs) |
| `szl-receipts-server-image.cdx.json` | Syft v1.18.1 | CycloneDX (JSON) | same image |
| `szl-receipts-server-image.zarf-embedded.spdx.json` | Zarf v0.51.0 (Syft engine) | SPDX (JSON) | same image, as embedded in the package's `sboms.tar` |

The Zarf package `szl-receipts` is self-contained: `zarf package create` bakes the
referenced images **and** a Syft-generated SBOM (`sboms.tar`) into the package
tarball. Extract all embedded SBOMs from a built/pulled package with:

```bash
zarf package inspect sbom zarf-package-szl-receipts-amd64-0.3.1.tar.zst --output ./sbom-extracted
# (the package also embeds SBOMs for docker.io/library/nginx:1.27-alpine and
#  ghcr.io/defenseunicorns/pepr/controller:v1.2.0)
```

## Regenerate the image SBOMs

```bash
IMG=ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1
syft "registry:$IMG" -o spdx-json=sbom/szl-receipts-server-image.spdx.json \
                     -o cyclonedx-json=sbom/szl-receipts-server-image.cdx.json
```

## Provenance

- Generated on Stephen's box (`167.233.50.75`) 2026-06-07 with `syft v1.18.1` /
  `zarf v0.51.0`.
- The image these SBOMs describe is cosign keyless-signed in CI
  (`receipts-server-image.yml`); see `warhacker-deliverables/SIGNED-SBOMED-PACKAGE-PUBLISH-2026-06-07.md`
  for the full signing + publish + round-trip evidence.
- SLSA honesty: build provenance is GitHub-Actions keyless attestation (SLSA L1/L2
  class). No SLSA L3, Iron Bank, FedRAMP, or CMMC claims are made.
