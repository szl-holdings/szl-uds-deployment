# Signed + SBOMed szl-receipts Package — Publish & Registry Round-Trip

**Date:** 2026-06-07
**Box:** `167.233.50.75:/opt/szl/szl-uds-deployment`
**Tooling:** cosign v2.4.1 · zarf v0.51.0 · syft v1.18.1 · uds v0.32.0 · k3d v5.9.0

This documents the supply-chain hardening of the `szl-receipts` UDS package: SBOMs
for image + package, cosign signing with passing verification, OCI publish to GHCR,
and a proven pull-back **and deploy** round-trip from the registry.

---

## 1. Artifacts

| Artifact | Reference / file |
|----------|------------------|
| Receipts image | `ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1` |
| Package (OCI) | `ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream` (digest `sha256:b87be8d0…`) |
| Package (airgap tarball) | `zarf-package-szl-receipts-amd64-0.3.1.tar.zst` (`sha256:887213527b2b…`, 220 MB) |
| Image SBOM (SPDX) | `sbom/szl-receipts-server-image.spdx.json` (Syft, 109 pkgs) |
| Image SBOM (CycloneDX) | `sbom/szl-receipts-server-image.cdx.json` (Syft) |
| Package-embedded image SBOM | `sbom/szl-receipts-server-image.zarf-embedded.spdx.json` (Zarf/Syft) |

The package is **self-contained**: `zarf package create` bakes the referenced images
(`szl-receipts-server:uds-v0.3.1`, `nginx:1.27-alpine`, `pepr/controller:v1.2.0`)
plus a Syft `sboms.tar` into the tarball, so a pull-back has everything to deploy
offline.

---

## 2. SBOMs (Syft + Zarf)

```bash
# Image SBOMs (SPDX 2.3 + CycloneDX)
IMG=ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1
syft "registry:$IMG" -o spdx-json=sbom/szl-receipts-server-image.spdx.json \
                     -o cyclonedx-json=sbom/szl-receipts-server-image.cdx.json

# Every SBOM embedded in a built/pulled package
zarf package inspect sbom zarf-package-szl-receipts-amd64-0.3.1.tar.zst --output ./sbom-extracted
```

SHA-256 (committed copies):

```
b11d48c31ab83811f255e2f6fc866a362ed81d83c72062cbb60b7309469b3dc1  szl-receipts-server-image.spdx.json
041fd1c3bb2527b3dbca9fefb122ba414a7353bf40c9c5eacee77410d59dd675  szl-receipts-server-image.cdx.json
0f45fdfe6e4ad15f534c743c50f7211e364fe9ba6fe3cf8d57d2bc7f33766134  szl-receipts-server-image.zarf-embedded.spdx.json
```

---

## 3. Signing & verification (cosign v2.4.1)

### Image — keyless OIDC (canonical, CI)
The image is signed keyless in GitHub Actions (`receipts-server-image.yml`). Verify:

```bash
cosign verify ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1 \
  --certificate-identity-regexp 'receipts-server-image.yml' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
# => "signatures were verified against the certificate" (transparency log: Verified OK)
```

### Package — cosign key-pair (headless/box publish)
The published OCI package and the airgap tarball are signed and verify cleanly:

```bash
# OCI artifact
cosign verify --key cosign.pub ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream
#   - Existence of the claims in the transparency log was verified offline
#   - The signatures were verified against the specified public key   ✅

# Airgap tarball (detached bundle)
cosign verify-blob --key cosign.pub \
  --bundle zarf-package-szl-receipts-amd64-0.3.1.tar.zst.cosign.bundle \
  zarf-package-szl-receipts-amd64-0.3.1.tar.zst
# => Verified OK   ✅
```

Verification public key (box run, 2026-06-07):

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjm2BLYjVHSASM+c1inu445m3WUym
IQCtbM6ZD1T0BMzEg5F4bj1ryoVe1edz/sENsx4vXZ0eCpVWVrp7V8Yz9w==
-----END PUBLIC KEY-----
```

> The key-pair above is an ephemeral box pair used for headless publish. For
> production releases, sign keyless in CI (same OIDC flow as the image) so no
> private key is ever stored — see the runbook.

---

## 4. Registry round-trip (publish → pull → deploy)

```bash
# Publish
zarf package publish zarf-package-szl-receipts-amd64-0.3.1.tar.zst \
  oci://ghcr.io/szl-holdings/packages

# Pull back (self-contained, 220 MB) — embedded images confirmed:
zarf package pull oci://ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream
zarf package inspect images zarf-package-szl-receipts-amd64-0.3.1.tar.zst
#   - ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1
#   - docker.io/library/nginx:1.27-alpine
#   - ghcr.io/defenseunicorns/pepr/controller:v1.2.0

# Deploy straight from the registry into the uds-core cluster (uds-szl-demo)
zarf package deploy oci://ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream \
  --confirm --set DOMAIN=uds.dev
```

**Deploy-from-registry proof (cluster `uds-szl-demo`, 2026-06-07):**

```
$ zarf package deploy oci://ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream --confirm --set DOMAIN=uds.dev
INF deploying component name=szl-receipts-namespace
INF deploying component name=szl-receipts-server
INF pushing image name=ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1
INF pushing image name=docker.io/library/nginx:1.27-alpine
INF performing Helm install chart=szl-receipts
INF running health checks chart=szl-receipts

$ zarf package list
     szl-receipts | 0.3.1 | [szl-receipts-namespace szl-receipts-server]

$ kubectl get pods,svc -n szl-receipts
pod/szl-receipts-server-956cc4b4b-dcctm   2/2     Running   0   95s
service/szl-receipts-server   ClusterIP   10.43.144.19   8080/TCP,80/TCP
```

The images deployed were pushed **from the pulled package** (self-contained), not
re-fetched from GHCR — confirming an airgap-capable round-trip. The UDS Package CR
reports `Retrying` while the uds-operator reconciles NetworkPolicies/Monitors; that
is the known package-definition selector/`sso` trap (version-consistency territory,
out of scope here) and does not affect the running workload.

---

## 5. Runbook (Stephen-only steps)

These steps need credentials/secrets only Stephen holds; everything else is in
`scripts/sbom-sign-publish-receipts.sh`.

1. **GHCR auth** — a PAT with `write:packages` on the `szl-holdings` org:
   ```bash
   echo "$SZL_GITHUB_TOKEN" | zarf tools registry login ghcr.io -u <user> --password-stdin
   echo "$SZL_GITHUB_TOKEN" | cosign login ghcr.io -u <user> --password-stdin
   ```
2. **Build + publish + sign + round-trip** (one shot):
   ```bash
   ./scripts/sbom-sign-publish-receipts.sh
   ```
3. **Production (keyless) signing** — preferred over the box key-pair. Tag a
   release; the `zarf-package-sign.yml` workflow signs keyless via GitHub OIDC, so
   no private key is stored. (Workflow fix applied this round — see §6.)
4. **Make the GHCR package public** (optional, for unauthenticated pull): org
   *Packages → szl-receipts → Package settings → Change visibility → Public*.
5. **Version-lock** the package's `uds-v0.4.0` image reference vs the GHCR
   `uds-v0.3.1` image — **tracked separately**, intentionally out of scope here
   (the package is self-contained, so the round-trip/deploy does not need it).

---

## 6. CI fix applied

`.github/workflows/zarf-package-sign.yml` built `uds/zarf.yaml` after the receipts
package, but that build aborted the whole step (so the receipts package never got
signed) because two **build-time** template vars had no value:
`###ZARF_PKG_TMPL_VAR_UDSMESH_IMAGE_TAG###` and `…A11OY_IMAGE_TAG###`. Fix: pass
them explicitly at build time:

```bash
zarf package create uds --set UDSMESH_IMAGE_TAG=latest --set A11OY_IMAGE_TAG=latest ...
```

---

## 7. Honesty / scope

- **Provenance level: SLSA L1/L2 class only** — GitHub-Actions keyless attestation +
  cosign signatures + Syft SBOMs. **No** SLSA L3, Iron Bank, FedRAMP, or CMMC
  claims.
- The cosign **transparency-log** entries are real (Rekor); the package signature in
  §3 uses a box key-pair, not keyless — production should move to keyless CI.
- Version-consistency (package `uds-v0.4.0` ref vs GHCR `uds-v0.3.1`) is **out of
  scope** and tracked elsewhere; it does not affect this self-contained round-trip.
