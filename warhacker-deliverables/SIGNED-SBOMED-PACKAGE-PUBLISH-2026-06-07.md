# Signed + SBOMed szl-receipts Package — Publish & Registry Round-Trip

**Date:** 2026-06-07
**Box:** `167.233.50.75:/opt/szl/szl-uds-deployment`
**Tooling:** cosign v2.4.1 · zarf v0.51.0 · syft v1.18.1 · uds v0.32.0 · k3d v5.9.0

This documents the supply-chain hardening of the `szl-receipts` UDS package: SBOMs
for image + package, cosign signing with passing verification, OCI publish to GHCR,
and a proven pull-back **and deploy** round-trip from the registry.

---

## Public pull + verify (no login, no key file) — TL;DR

> **UPDATE (keyless):** current releases are signed **keyless via GitHub OIDC** in
> CI (`.github/workflows/zarf-package-sign.yml`) — no committed key, no stored
> private key. The key-pair flow below is **legacy** (the original `0.3.1-upstream`
> publish only). Verify the current package with **no key file**:

```bash
cosign verify ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream \
  --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/zarf-package-sign.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
# => "signatures were verified against the certificate" (Rekor transparency log: Verified OK)

# Full self-contained airgap package (~220 MB) for offline deploy:
zarf package pull oci://ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream
```

<details><summary>RETIRED — original 0.3.1-upstream internal artifact (historical record, NOT a verification path)</summary>

> The internal package `ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream`
> is **RETIRED** and `internal` visibility on GHCR. It was an off-CI artifact signed
> with an **ephemeral box key-pair whose private half is gone**, so nothing further
> will ever be signed with it. It is **not** authoritative and **not** a verification
> path — use the keyless `0.4.0-upstream` command above. The decision and rationale
> for keeping it as a frozen historical record (rather than deleting it) are in
> `cosign/README.md`. For the historical record only, it was signed with the
> ephemeral key whose public half is `cosign/szl-receipts-package.pub`
> (Rekor logIndex 1752638899).
</details>

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
  --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/receipts-server-image.yml@refs/heads/fix/uds-deploy-stall-gaps" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
# => "signatures were verified against the certificate" (transparency log: Verified OK)
```

### Package — keyless OIDC (canonical, CI)
The published OCI package is signed **keyless** in GitHub Actions
(`zarf-package-sign.yml`, which now `zarf package publish`es the package to GHCR
and `cosign sign`s the published OCI ref). Verify with **no key file**:

```bash
cosign verify ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream \
  --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/zarf-package-sign.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
# => signatures verified against the cert; transparency log: Verified OK   ✅

# Airgap tarball (detached keyless bundle, also produced by CI):
cosign verify-blob \
  --bundle zarf-package-szl-receipts-amd64-0.4.0.tar.zst.cosign.bundle \
  --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/zarf-package-sign.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  zarf-package-szl-receipts-amd64-0.4.0.tar.zst
# => Verified OK   ✅
```

<details><summary>RETIRED — original key-pair publish (0.3.1-upstream internal artifact, historical record only)</summary>

> **Do not use this as a verification path.** The internal `0.3.1-upstream` package
> is RETIRED; the current, authoritative artifact is the keyless `0.4.0-upstream`
> above. The block below is preserved only as a record of how the retired artifact
> was originally signed.

The original `0.3.1-upstream` artifact was signed with an ephemeral box key-pair
whose public half is committed at `cosign/szl-receipts-package.pub`. It was
historically checkable with (kept for the record, not for current use):

```bash
cosign verify --key cosign/szl-receipts-package.pub \
  ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream
#   - The signatures were verified against the specified public key   ✅

cosign verify-blob --key cosign/szl-receipts-package.pub \
  --bundle zarf-package-szl-receipts-amd64-0.3.1.tar.zst.cosign.bundle \
  zarf-package-szl-receipts-amd64-0.3.1.tar.zst
# => Verified OK   ✅
```

Retired public key (box run, 2026-06-07; private half ephemeral and gone):

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjm2BLYjVHSASM+c1inu445m3WUym
IQCtbM6ZD1T0BMzEg5F4bj1ryoVe1edz/sENsx4vXZ0eCpVWVrp7V8Yz9w==
-----END PUBLIC KEY-----
```

The private half was ephemeral and is gone; no further artifacts will be signed
with it. New releases are keyless (above), so no key custody is required.
</details>

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
3. **Production (keyless) signing — now the default, no Stephen step.** Every push
   to `main` runs `zarf-package-sign.yml`, which `zarf package publish`es the
   szl-receipts package to GHCR **and** `cosign sign`s the published OCI ref keyless
   via GitHub OIDC. No private key is stored and no public key is committed. The
   box key-pair publish (steps 1–2) is now legacy/optional.
4. **Make the GHCR package public** — required for unauthenticated pull/verify.
   GitHub's REST API has **no** package-visibility endpoint (`PATCH
   .../packages/container/...` returns 404), so an org owner flips it once in the
   web UI:
   *github.com/orgs/szl-holdings → Packages → `szl-receipts` → Package settings →
   Danger Zone → Change visibility → **Public***.
   Then confirm anonymous, **keyless** access works (no key file):
   ```bash
   docker logout ghcr.io
   cosign verify ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream \
     --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/zarf-package-sign.yml@refs/heads/main" \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com
   ```
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

- **Provenance level: SLSA L1 honest on this bundle** — GitHub-Actions keyless
  attestation + cosign signatures + Syft SBOMs. The verified L2 on organ images is
  attested on the five organ images only; bundle-level SLSA attestation is **NOT
  earned** (the cosign signature is the bundle provenance). This is **not L3**.
  No Iron Bank, no FedRAMP, no CMMC claims.
- The cosign **transparency-log** entries are real (Rekor). The original
  `0.3.1-upstream` package signature used an ephemeral box key-pair; current
  releases are signed **keyless** in CI (`zarf-package-sign.yml` now publishes the
  package to GHCR and `cosign sign`s the published OCI ref), so no private key is
  stored and no public key is committed.
- Version-consistency (package `uds-v0.4.0` ref vs GHCR `uds-v0.3.1`) is **out of
  scope** and tracked elsewhere; it does not affect this self-contained round-trip.

