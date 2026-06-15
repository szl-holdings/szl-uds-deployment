<!-- SPDX-License-Identifier: Apache-2.0 -->
# UDS Ecosystem Alignment + Deploy Proof — 2026-06-15

**Author:** Forge (SZL Holdings CTO/engineer)
**Box:** 167.233.50.75 · repo `/opt/szl/szl-uds-deployment` @ main `c827a42` · VERSION `uds-v0.4.0`
**Cluster:** k3d `uds-szl-demo` (k8s v1.35.5, Ready 7d+)

## Scope
End-to-end verification that the SZL UDS payload/ecosystem is (1) aligned with
GitHub/GHCR (and the HF-published organ images), (2) passes the UDS test/guard
suite, and (3) is deployable + actually serving in a live UDS environment.
Read-only + additive (this one report file); no mutation of the live cluster.

## 1. Alignment (UDS payload <-> GitHub / GHCR / HF) — GREEN
| Guard | Result |
|---|---|
| `scripts/check_version_doctrine.sh` | PASS |
| `scripts/organ-pin-drift-guard-checks.sh` | PASS |
| `scripts/pin-drift-guard-checks.sh` | PASS |
| `scripts/image-stale-watch-guard-checks.sh` | PASS (live a11oy/killinchu images NOT behind origin/main) |
| `scripts/bundle-digest-watch-guard-checks.sh` | PASS |
| `scripts/bundle-digest-recut-guard-checks.sh` | PASS |
| `scripts/oci-ref-checks.py check .` | PASS — `oci://ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream` resolves anonymously on GHCR (HTTP 200) |
| `scripts/deploy-entry-checks.py check .` | PASS — every component in `uds/zarf.yaml` internally consistent |

## 2. UDS test/validation suite — GREEN
| Check | Result |
|---|---|
| `scripts/clean-deploy-checks.sh` | PASS |
| `scripts/bundle-build-guard.py` | PASS |
| `tests/uds-catalog-validation.sh` | PASS |
| guard self-tests: image-pin / oci-ref / chart-guard / deploy-entry `.test.py` | PASS |

## 3. Build proof — signed, digest-pinned, deployable artifact
- `uds-bundle-szl-receipts-bundle-amd64-0.4.0.tar.zst` (707 MB) airgap bundle,
  keyless-signed (uds inspect requires --certificate-identity/--certificate-oidc-issuer,
  confirming the Sigstore signature; FA-002 resolved).
- Bundle composition (all digest-pinned):
  - init ghcr.io/zarf-dev/packages/init v0.77.0@sha256:3c9eca5c10d6...
  - core-base ghcr.io/defenseunicorns/packages/uds/core-base 1.5.0-upstream@sha256:f78774b9c0a7...
  - core-identity-authorization 1.5.0-upstream@sha256:18c302ec0112...
  - szl-receipts (local) 0.4.0@sha256:193f4477880d...
- `packages/szl-receipts/zarf-package-szl-receipts-amd64-0.4.0.tar.zst` (83 MB)
  valid ZarfPackageConfig, flavor `upstream`, aggregateChecksum 683f3c94...
- Small-box rightsizing baked into overrides (istiod autoscaleMax=1, pilot cpu=150m, tenant gateway ClusterIP).

## 4. Deploy proof — live UDS environment
Zarf packages installed in `uds-szl-demo`: core 1.5.0 (istio CP, both gateways,
keycloak, authservice, falco, loki, kube-prometheus-stack), init v0.77.0,
szl-a11oy 0.2.0, szl-receipts 0.4.0.

UDS Package CRs — all **Ready**: a11oy (a11oy.admin.uds.dev), killinchu
(killinchu.admin.uds.dev), szl-receipts (receipts.uds.dev), keycloak
(sso.uds.dev + keycloak.admin.uds.dev), authservice.

Live reachability:
- **a11oy -> HTTP 200 (real UI HTML) through the istio admin gateway**
  (--resolve a11oy.admin.uds.dev:443:172.18.0.2) and direct — full
  external->mesh->pod path proven.
- killinchu -> HTTP 307 (up, redirecting).
- szl-receipts-server -> responding (HTTP 404 on `/`; path-based API, server alive).
- Non-SNI TLS to the gateway IP -> 000, confirming istio SNI-based routing is enforced.

## 5. Honest ceilings / open items
- **Box resource ceiling (8 GB RAM / ~2 vCPU, disk 84%).** A *second* full UDS
  Core cluster does not fit alongside the live demo; a clean teardown->redeploy
  was therefore NOT exercised on prod. Upgrade-survival is covered by CI
  `uds run test-upgrade` (receipts + signing key survive a helm upgrade on a
  throwaway cluster).
- **FA-001 — RESOLVED (2026-06-15) by consolidation.** Vessels is folded into
  the killinchu organ; there is no standalone `ghcr.io/szl-holdings/vessels`
  image to publish. The maritime/sanctions surface ships inside the published,
  cosign-signed `killinchu:uds-v0.2.0` organ — live probe: `GET /vessels` and
  `GET /sanctions` both 200 on the running organ — deployed via
  `bundles/killinchu` (killinchu-bundle:0.5.0, published + current). No org
  `admin:packages` action and no blocked deploy path remain. The legacy
  `uds/zarf.yaml` (szl-vessels-demo) + `charts/vessels` are kept as REFERENCE
  only (superseded by the killinchu organ).
- Tenant gateway is ClusterIP **by design** (small-box override); tenant-host
  reachability requires port-forward, not a node LB.

## Verdict: GO
UDS payload is aligned with GitHub/GHCR, passes the full guard/validation suite,
builds into a signed digest-pinned airgap bundle, and is deployed + serving in
the live UDS environment (a11oy returns 200 through the istio gateway). The only
remaining ceiling on a complete multi-organ one-command bring-up is the box
resource ceiling for a parallel full cluster. FA-001 is RESOLVED: vessels is
consolidated into the published, live killinchu organ (see §5), so no
founder-gated vessels publish is required.
