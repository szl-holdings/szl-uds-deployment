<!-- Copyright 2026 SZL Holdings · SPDX-License-Identifier: Apache-2.0 -->
# a11oy.uds — deploy + prove-it

`a11oy.uds` composes the **governed-AI decision substrate** (a11oy) into a single
air-gapped UDS bundle that `uds create` + `uds deploy`s on a single tower with
**one command**. The former `sentra` (immune/safety gates) and `amaru` (memory)
backends are no longer separate members — they were consolidated INTO a11oy as
internal organs and ship inside the a11oy image; a11oy boots standalone against
`szl-receipts`.

- **Kind:** `UDSBundle` (uds-cli, AGPL-3.0, defenseunicorns/uds-cli). Original SZL work; we use the binary, not its source.
- **Members:** `szl-a11oy` (0.5.0-uds.0, built from `packages/a11oy/zarf-mesh-ready.yaml`, flavor `upstream`).
- **Doctrine v11:** locked-8 @ `c7c0ba17`, Λ = Conjecture 1, SLSA L1 honest / L2 attested / L3 ROADMAP, tamper-EVIDENT (SHA3-256 hash-chain), NEVER commit a key, honest BLOCKED beats fake green.

## Air-gap posture (CONFIRMED)
- Organ image is **digest-pinned** in every source file: `ghcr.io/szl-holdings/a11oy:uds-v0.3.0@sha256:bafd3f37b0f12b781fa57fe263739d0ff8cc1f9547e78c2df5f8b059fa6478b4` (single-arch v2 manifest — create-safe, not an OCI index).
- `uds zarf package create` **bakes** every image into the package tarball; at deploy the Zarf agent rewrites image refs to the **in-cluster** registry. **No runtime CDN, no internet pull at deploy.**
- Pin is re-asserted against the live GHCR digest by `prove-it.sh` step `[1] VALIDATE` — re-resolve before an air-gap freeze in case CI rebuilds the organ.

## Prove it
```bash
cd bundles/a11oy
./prove-it.sh validate   # schema + digest-pin + doctrine (no docker; runs anywhere)
./prove-it.sh build      # + uds zarf package create (members) + uds create (needs docker + ghcr login)
./prove-it.sh deploy     # + k3d + UDS Core + uds deploy + hit /healthz & /honest, assert locked=8 @ c7c0ba17
```
`deploy` asserts `locked_formula_count=8`, `commit=c7c0ba17`, `lambda=Conjecture 1`
on `/honest`, prints the hash-chained (tamper-EVIDENT) receipt ledger and the
per-organ cosign verify-key. Any step needing docker / GHCR-pull / the founder
key that is unavailable prints **BLOCKED (reason)** and continues — it never
fabricates a green result.

## Exact create/deploy commands (founder tower)
```bash
# 1. build the member package (organ image baked in, digest-pinned)
cp packages/a11oy/zarf-mesh-ready.yaml packages/a11oy/zarf.yaml
uds zarf package create packages/a11oy --set DOMAIN=uds.dev -a amd64 --flavor upstream --confirm
# 2. compose the bundle (air-gap tarball)
uds create bundles/a11oy --confirm -a amd64
# 3. deploy on the tower (images already baked — no internet needed)
uds deploy bundles/a11oy --confirm
```

## Signed vs FOUNDER-GATED
- **SIGNED (keyless, no founder key):** organ images cosign keyless-signed (Sigstore/Fulcio OIDC) by `cosign.yml` on push → SLSA L1 honest; runtime receipt ledger is SHA3-256 hash-chained (tamper-EVIDENT).
- **FOUNDER-GATED (FA-001 key, NEVER committed/faked):** `cosign sign` of the published `a11oy-bundle:0.5.0` OCI artifact. The published bundle on GHCR is currently STALE (built against an older organ) and must be re-published against the fresh organ, then signed. See `team/AUDIT/warroom/UDS_COSIGN_FOUNDER_HANDOFF.md`.
- **HONEST FLAG (not auto-fixed):** a11oy `/khipu/pubkey` currently serves the org-root key (`szlholdings-cosign`, `76199818…`), not the per-organ key the MANIFEST declares (`f042ba5a…`). Founder decision: repoint a11oy OR update the MANIFEST.

> **NOTE — mutable tag:** `uds-v0.3.0` is rebuilt frequently by CI; the digest above was verified-current + stable on 2026-06-15 but MUST be re-resolved (`prove-it.sh validate` asserts it live) immediately before an air-gap freeze.
