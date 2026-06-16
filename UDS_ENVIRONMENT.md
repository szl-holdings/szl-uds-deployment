# UDS Environment — SZL a11oy + killinchu (validated 2026-06-09)

**What UDS is** (Defense Unicorns, verified from docs.defenseunicorns.com / docs.zarf.dev): Unicorn
Delivery Service — a secure, airgap-native Kubernetes runtime platform built on **Zarf** (airgap OCI
packaging) + **Pepr** (policy engine / operator). UDS Core provides hardened shared services (Istio
service mesh — Ambient mode as of core v0.43.0: ztunnel L4 + optional waypoint L7; Keycloak SSO; logging;
monitoring; runtime security), targeting NIST SP 800-53 / DoD Zero Trust / ATO with SBOM + CVE evidence.

**Non-affiliation:** SZL Holdings is NOT affiliated with or endorsed by Defense Unicorns. We build
UDS-*compatible* packages using the open-source Zarf + Pepr + UDS Package CR pattern. We do NOT vendor or
adopt the AGPL `uds-core` itself — it is referenced as a deployment *pattern* only.

## SZL UDS artifacts — VALIDATED (all YAML parses, correct kinds)
| Artifact | Path (uds-bundles) | Kind | Status |
|---|---|---|---|
| a11oy product bundle | bundles/a11oy/uds-bundle.yaml | UDSBundle v0.5.0 | ✓ valid |
| killinchu product bundle | bundles/killinchu/uds-bundle.yaml | UDSBundle v0.5.0 | ✓ valid |
| a11oy zarf package | bundles/szl-a11oy/zarf.yaml | ZarfPackageConfig | ✓ valid |
| a11oy UDS Package CR | bundles/szl-a11oy/manifests/uds-package.yaml | Package (Pepr CR) | ✓ valid |
| killinchu UDS Package CR | bundles/szl-killinchu/manifests/uds-package.yaml | Package (Pepr CR) | ✓ valid |
| Helm charts | bundles/szl-{a11oy,killinchu}/chart/ | Chart.yaml + values | ✓ present |

Each product = the correct UDS 3-layer structure: **ZarfPackageConfig** (declarative OCI artifact
wrapping the Helm chart) → **Package CR** (integrates with UDS Core via Pepr; sets service-mesh
mode) → **UDSBundle** (uds-cli combines packages, publishes to `oci://ghcr.io/szl-holdings/<p>-bundle:0.5.0`).
Governance capabilities live in szl-uds-deployment/capabilities/szl-governance (pepr.ts +
{a11oy,killinchu}-receipt-gate.ts) — Λ-signed receipt admission gates.

## OPEN DOCTRINE ITEM (flagged to DEV-A this round)
UDS repos still carry banned codenames as package/bundle/manifest names (amaru/yupana/sentra) — 225 paths
across uds-bundles/szl-uds-deployment/szl-fleet-overlay/uds-mesh. Must be renamed to honest roles
(amaru→provenance-anchor, yupana→operator, sentra→policy) WITH full cross-reference integrity, or flagged
for a focused pass. Tracked.

## Local UDS environment — how to stand it up (k3d-core-dev-slim)
Real K8s can't run in the build sandbox, so deploy is documented + scripted (honestly simulated here;
runs for real on a host with Docker + the UDS CLI):

```bash
# 1. Install UDS CLI (Defense Unicorns)
brew install defenseunicorns/tap/uds   # or: see github.com/defenseunicorns/uds-cli releases

# 2. Stand up a dev cluster with UDS Core slim baseline
uds run create-cluster                  # k3d cluster
# (or) k3d cluster create uds --servers 1 --agents 1

# 3. Build the SZL product bundles (from uds-bundles/)
cd bundles/szl-a11oy   && uds zarf package create .   && cd -
cd bundles/szl-killinchu && uds zarf package create . && cd -
uds create bundles/a11oy      # builds the a11oy UDSBundle (pulls the zarf pkgs it imports)
uds create bundles/killinchu

# 4. Deploy to the dev cluster
uds deploy a11oy-bundle-*.tar.zst --confirm
uds deploy killinchu-bundle-*.tar.zst --confirm

# 5. Verify the UDS Package CRs reconcile via Pepr + the Λ-receipt gate admits
kubectl get packages -A
kubectl logs -n pepr-system -l app=pepr-uds-core | grep -i "szl-governance"
```

NOTE: the receipt-gate capabilities require the cosign key (now set as runtime secret
SZL_COSIGN_PRIVATE_KEY_PEM) for live DSSE signing; the published bundles are SBOM'd + cosign-signed at
L1-honest (L2 build-attestation = roadmap, not claimed).

## Verdict
SZL UDS payloads for a11oy + killinchu are **structurally correct and UDS-compatible** (valid Zarf +
Package CR + UDSBundle, Helm charts, governance gates). Ready to build/deploy on a UDS Core dev cluster.
Two items before "production-clean": (1) the codename→honest-role rename across UDS repos; (2) build +
deploy verification on a real k3d-core-dev-slim host (out of sandbox scope — documented above).
