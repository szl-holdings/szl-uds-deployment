<!-- Copyright 2026 SZL Holdings · SPDX-License-Identifier: Apache-2.0 -->
# killinchu.uds — deploy + prove-it  (counter-UAS / maritime C2 · effectors SIMULATED)

`killinchu.uds` composes the **counter-UAS / maritime C2** organ (killinchu) plus
its backends (sentra, amaru) into a single air-gapped UDS bundle.

> **HARD SAFETY DOCTRINE:** every effector is **SIMULATED, human-on-loop**. There
> is **NO live weapon, vessel, or actuator control** anywhere in this package. The
> prove-it script ASSERTS `effector=SIMULATED` on every engagement path and treats
> any non-SIMULATED value as a safety violation.

- **Kind:** `UDSBundle` (uds-cli, AGPL-3.0). Original SZL work; binary only.
- **Members:** `szl-sentra` (0.2.0) → `szl-amaru` (0.2.0) → `szl-killinchu` (built from `packages/killinchu/zarf-mesh-ready.yaml`, flavor `upstream`).
- **Doctrine v11:** locked-8 @ `c7c0ba17`, Λ = Conjecture 1, SLSA L1 honest / L2 attested / L3 ROADMAP, tamper-EVIDENT, NEVER commit a key, honest BLOCKED beats fake green.

## Air-gap posture (CONFIRMED)
- Organ image digest-pinned in every source file: `ghcr.io/szl-holdings/killinchu:uds-v0.2.0@sha256:6f185dda4e81aa2a347a5210a2f2bdfd19fe1af898e0c14a0a914261b1858f16` (single-arch v2 manifest — create-safe).
- `uds create` bakes images into the tarball; deploy rewrites to the in-cluster registry. **No runtime CDN, no internet pull at deploy.** Pin re-asserted live by `prove-it.sh` step `[1]`.

## Prove it
```bash
cd bundles/killinchu
./prove-it.sh validate   # schema + digest-pin + doctrine (no docker)
./prove-it.sh build      # + member packages + uds create (needs docker + ghcr login)
./prove-it.sh deploy     # + k3d + UDS Core + uds deploy + endpoint asserts
```
`deploy` asserts `locked=8 @ c7c0ba17`, `Λ=Conjecture 1`, then exercises:
- `GET /api/killinchu/v1/cuas/engage` — proportional-nav guidance solver; **ASSERTS `effector=SIMULATED` & `status=SIMULATED`**.
- `GET /api/killinchu/v1/cuas/wta` — weapon-target assignment (SIMULATED).
- `GET /api/killinchu/v1/gov/chapaq-verdict` — **human-on-loop ROE gate** (`allow`/`deny`) enforced before any SIMULATED engagement is modelled.
- `GET /api/killinchu/v1/receipt/ledger` — ROE-eval receipt ledger (hash-chained; cosign signature founder-gated, currently honest PLACEHOLDER).
- UI routes (Cesium globe): `/tracks /board /roe /effectors /elite /demos`.

## Exact create/deploy commands (founder tower)
```bash
uds zarf package create packages/sentra --set VERSION=0.2.0 -a amd64 --confirm
uds zarf package create packages/amaru  --set VERSION=0.2.0 -a amd64 --confirm
cp packages/killinchu/zarf-mesh-ready.yaml packages/killinchu/zarf.yaml
uds zarf package create packages/killinchu --set DOMAIN=uds.dev -a amd64 --flavor upstream --confirm
uds create bundles/killinchu --confirm -a amd64
uds deploy bundles/killinchu --confirm
```

## Signed vs FOUNDER-GATED
- **SIGNED (keyless):** organ image cosign keyless-signed by `cosign.yml` on push → SLSA L1 honest. `/khipu/pubkey` serves `killinchu-cosign` (`f208cba3…`) which **MATCHES** the package MANIFEST declared key. Receipt ledger SHA3-256 hash-chained (tamper-EVIDENT).
- **FOUNDER-GATED (FA-001, NEVER faked):** `cosign sign` of the published `killinchu-bundle:0.2.0` OCI artifact; and the per-receipt cosign signature — the ledger honestly states *"Signatures PLACEHOLDER — Sigstore CI signing not yet wired into CI per Doctrine v11."* The ROE decision + hash-chain are real; the signature is founder-gated.
- **NOT L3:** bundle-level SLSA L2 build-provenance attestation NOT earned (CI token lacks `attestations:write`) — the cosign signature is the bundle provenance.

> **NOTE — mutable tag:** `uds-v0.2.0` is rebuilt frequently by CI; the digest above was verified-current + stable on 2026-06-15 but MUST be re-resolved (`prove-it.sh validate` asserts it live) immediately before an air-gap freeze.
