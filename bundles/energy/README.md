<!-- Copyright 2026 SZL Holdings · SPDX-License-Identifier: Apache-2.0 -->
# energy.uds — deploy + prove-it  (wasted-energy harvest grid signal)

`energy.uds` wraps the **wasted-energy harvest grid signal** (`packages/energy-harvest`)
into a single UDS bundle. It reads three **public, no-key** grid feeds and reports
when the grid is **WASTING power** (negative wholesale price / curtailed renewables)
so already-wasted energy can be soaked.

> **HONEST STATUS — this payload is VALIDATED, not yet live, by design:**
> 1. **Image GATED:** `ghcr.io/szl-holdings/energy-harvest` is **NOT published** (GHCR returns 403/DENIED). `uds create` is gated until it is built + pushed + cosign-signed + digest-pinned. **No fabricated digest is pinned.**
> 2. **Joules are SAMPLE, not MEASURED:** there is **no on-box NVML joule exporter yet**, so this payload does **NOT** emit MEASURED-joule signed "JouleCharge" receipts. That is a **ROADMAP** item. What is real today: live public grid feeds + a Prometheus gauge `szl_energy_harvest_joules_sample=1` that DECLARES the joules are sampled.
> Honest BLOCKED beats fake green.

- **Kind:** `UDSBundle` (uds-cli, AGPL-3.0). Original SZL work; binary only.
- **Member:** `szl-energy-harvest` (0.1.0, built from `packages/energy-harvest/zarf.yaml`).
- **Doctrine v11:** joules SAMPLE, NEVER `sovereign:true`, NOT one of the locked-8, Λ = Conjecture 1. No free-energy, no greenwashing, no fabricated joules.

## Air-gap posture
- The package is manifest-based (namespace + UDS Package CR + Deployment/Service), `uds zarf dev lint` clean. Three external-feed **egress** NetworkPolicies are declared (`api.awattar.de`, `api.energy-charts.info`, `api.carbonintensity.org.uk`) — those feeds are the signal's only egress, and are explicit + auditable.
- Once the image is published + digest-pinned, `uds create` bakes it into the tarball (no runtime CDN at deploy).

## Prove it
```bash
cd bundles/energy
./prove-it.sh validate   # schema + manifest consistency + image-gate check + live-endpoint honesty
./prove-it.sh build      # GATED: only runs uds create once the image is published
./prove-it.sh deploy     # GATED: build + k3d + uds deploy once the image is published
```
The endpoint asserts (in-cluster or against the live reference instance) check
`joules_label=SAMPLE` and `sovereign=false` on `/fabric`, and show the honest
`/metrics` gauges. Step `[2] IMAGE GATE` prints **BLOCKED** with the exact
go-live proof path while the image is unpublished — it never fakes a deploy.

## Go-live + create/deploy commands (founder / build dev)
```bash
# 1. build + push the image (cosign.yml keyless-signs on push -> SLSA L1)
docker build -t ghcr.io/szl-holdings/energy-harvest:uds-v0.1.0 packages/energy-harvest
docker push  ghcr.io/szl-holdings/energy-harvest:uds-v0.1.0
# 2. digest-pin the linux/amd64 child in BOTH:
#      packages/energy-harvest/zarf.yaml          (uncomment the images: entry)
#      packages/energy-harvest/manifests/deployment.yaml
# 3. build the package + bundle
uds zarf package create packages/energy-harvest --set VERSION=0.1.0 -a amd64 --confirm
uds create bundles/energy --confirm -a amd64
# 4. deploy
uds deploy bundles/energy --confirm
```

## Signed vs FOUNDER-GATED
- **SIGNED (keyless, after publish):** `cosign.yml` keyless-signs the image on push → SLSA L1 honest.
- **FOUNDER-GATED (FA-001, NEVER faked):** `cosign sign` of the published `energy-bundle:0.1.0` OCI artifact.
- **ROADMAP (honest gaps):** image publish; on-box NVML MEASURED-joule exporter + signed JouleCharge receipt chain. Until then the payload is honestly **SAMPLE**.
