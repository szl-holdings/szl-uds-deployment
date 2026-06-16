# SZL — Mesh-Ready for UDS

[<img alt="Made for UDS" src="https://raw.githubusercontent.com/defenseunicorns/uds-common/refs/heads/main/docs/assets/made-for-uds.svg" height="20px"/>](https://github.com/defenseunicorns/uds-core)

**SPDX-License-Identifier: Apache-2.0** · Copyright 2026 SZL Holdings

> **Built to mesh with [UDS Core](https://github.com/defenseunicorns/uds-core).**
> SZL Holdings is **not affiliated with, sponsored by, or endorsed by Defense Unicorns.**
> Our packages are permissively licensed (Apache-2.0); they **interoperate** with the
> AGPL-3.0 UDS toolchain by targeting its public APIs (UDS Package CRs, UDS Bundles,
> Zarf packages) and invoking its binaries — we copy **no** AGPL source.

This document is the single entry point for deploying the SZL governed-AI substrate
(**a11oy**, **killinchu**) onto a UDS Core cluster, the SZL Pepr governance capability,
and the SZL Lula/OSCAL compliance assessment.

---

## 1. Deploy commands

### Preferred — maintained all-in-one mesh (today)

```bash
# UDS Core (Defense Unicorns, AGPL-3.0) — prerequisite
uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --confirm

# SZL all-in-one mesh — VERIFIED-LIVE on GHCR (sha256:7f5fce32…)
uds deploy oci://ghcr.io/szl-holdings/szl-mesh:0.4.0 --confirm
```

### Per-app bundles

```bash
# killinchu bundle — VERIFIED CURRENT on GHCR (sha256:e5992133…)
uds deploy oci://ghcr.io/szl-holdings/killinchu-bundle:0.5.0 --confirm

# a11oy bundle — PUBLISHED but STALE (sha256:d801f8e4…, built against an older
# a11oy organ image; the organ image was rebuilt to sha256:99e4ded1…).
# RE-PUBLISH via .github workflow uds-canonical-bundles-publish.yml (bundle=a11oy)
# and re-verify the new digest BEFORE deploying:
uds deploy oci://ghcr.io/szl-holdings/a11oy-bundle:0.5.0 --confirm   # verify digest first
```

### Build from source (this repo)

```bash
# Mesh-ready Zarf packages (upstream flavor pins VERIFIED organ images)
uds zarf package create packages/a11oy     -f zarf-mesh-ready.yaml --set DOMAIN=uds.dev -a amd64 --flavor upstream --confirm
uds zarf package create packages/killinchu -f zarf-mesh-ready.yaml --set DOMAIN=uds.dev -a amd64 --flavor upstream --confirm

# Bundles
uds create bundles/a11oy     --confirm
uds create bundles/killinchu --confirm

# Pepr governance capability
( cd capabilities/szl-governance && npm run build )      # pepr build -> dist/ (needs Docker)
uds zarf package create capabilities/szl-governance --confirm

# Lula/OSCAL compliance assessment (against a live cluster)
lula validate -f compliance/oscal-component-a11oy.yaml
lula validate -f compliance/oscal-component-killinchu.yaml
lula validate -f compliance/oscal-component-sda.yaml
```

> **Flavors:** `upstream` pins the **VERIFIED-LIVE** `uds-v0.2.0` organ images by digest
> and is buildable/deployable today. `unicorn` targets Wolfi/Chainguard `0.5.0-wolfi`
> images that are **not yet published** (HTTP 404) — **verify before deploy.**

---

## 2. UDS Package Custom Resources

Two profiles ship per app (both conform to `uds.dev/v1alpha1`; neither copies uds-core source):

| File | Profile | Mesh mode | Namespace | Audience |
| --- | --- | --- | --- | --- |
| `packages/<app>/uds-package.yaml` | mesh-**internal** (pre-existing) | sidecar | `szl-<app>` | service-to-service organ mesh |
| `packages/<app>/uds-package-mesh-ready.yaml` | mesh-**ready** (new, this work) | ambient | `<app>` | tenant-facing / demo |

The **mesh-ready** CRs declare the full governed surface from `team/UDS_MESH_READY_SPEC.md §3`:

- **`network.expose`** → Istio `VirtualService` entries with `uptime` health checks
  (tenant gateway for UI/API, admin gateway for metrics).
- **`network.allow`** → UDS-operated NetworkPolicies on top of default-deny:
  Prometheus scrape, Keycloak OIDC, **szl-receipts DSSE**, OTel collector, Loki, KubeAPI,
  in-namespace Postgres ledger.
- **`sso`** → Keycloak OIDC client with `enableAuthserviceSelector` (authservice sidecar
  injection — the app implements no auth middleware of its own).
- **`monitor`** → Prometheus `ServiceMonitor` for app / API / ledger metrics.

> The pre-existing internal CRs were **preserved** (non-destructive). Pick the profile that
> matches the deployment: tenant-facing demo → `*-mesh-ready.yaml`; internal organ mesh →
> `uds-package.yaml`.

---

## 3. Pepr governance capability — `capabilities/szl-governance/`

Apache-2.0 TypeScript Pepr module. Registers two admission gates:

- **`a11oy-receipt-gate`** (namespace `a11oy`)
- **`killinchu-receipt-gate`** (namespace `killinchu`, adds `szl.io/domain=maritime-drone-c2`)

**REAL (shipping):** validates that every non-system Pod carries a well-formed SZL
YUYAY-gate receipt annotation and **denies admission** if it is absent or malformed.

```
szl.io/receipt: "v1:<64-hex-sha256>:<base64url-dsse-signature>"
regex: ^v1:[0-9a-f]{64}:[A-Za-z0-9\-_=]{88,}$
```

**ROADMAP (clearly labeled in code):** full DSSE **cryptographic** signature verification
in-cluster against `szl-receipts` (egress already provisioned), Λ-gate score threshold,
ledger append. Uses only the `pepr` (Apache-2.0) public API — no AGPL source. See
`capabilities/szl-governance/README.md`.

---

## 4. Lula / OSCAL compliance — `compliance/`

OSCAL 1.1.2 component-definitions runnable with **lula1** (Apache-2.0):

```bash
lula validate -f compliance/oscal-component-a11oy.yaml
lula validate -f compliance/oscal-component-killinchu.yaml
lula validate -f compliance/oscal-component-sda.yaml
```

Five NIST SP 800-53 Rev 5 controls per app, each backed by an OPA/Rego policy that
queries **live Kubernetes state**:

| Control | Component | What the Rego checks (REAL) | ROADMAP |
| --- | --- | --- | --- |
| **SI-7** | Pepr Receipt Gate | szl-pepr-governance ValidatingWebhook present + pepr-system pod Running | Full DSSE verify |
| **AC-7** | Pepr Receipt Gate | gate enforced on every admission (same webhook resource) | Denial Prometheus counter |
| **AU-9** | Append-Only Ledger | `audit-db-credentials` Secret exists in namespace | WAL tamper detection (SLSA L2 verification on roadmap; L1 honest today) |
| **AU-3** | Append-Only Ledger | `<app>-ledger-schema` ConfigMap declares all 7 required fields | — |
| **SA-17** | Conjunctive Λ-Gate | `szl-<app>-gate-config` ConfigMap has all 6 gate keys = "true" | gate-score annotation |

> Λ = **Conjecture 1** (empirically CI-green on `main @ 958c09f9`; **not** a mathematical theorem).

---

## 5. Honest REAL-vs-ROADMAP matrix

| Item | Status | Notes |
| --- | --- | --- |
| Mesh-ready UDS Package CRs (expose/allow/sso/monitor) | **REAL** | Valid `uds.dev/v1alpha1`; reconciled by UDS Operator at deploy |
| Zarf packages (upstream + unicorn flavors) | **REAL (upstream) / ROADMAP (unicorn)** | upstream pins VERIFIED `uds-v0.2.0`; unicorn `0.5.0-wolfi` not yet published (404) |
| UDS Bundles (one-command deploy) | **REAL** | killinchu-bundle CURRENT; a11oy-bundle **STALE** — re-publish + re-verify |
| Pepr receipt-gate (format + presence) | **REAL** | TypeScript type-checks against pepr 0.40.0; denies malformed/absent receipts |
| Pepr full DSSE cryptographic verify | **ROADMAP (P1)** | egress pre-provisioned; hook commented in `szl-governance-common.ts` |
| Lula OSCAL controls (5 each, live K8s + Rego) | **REAL (structure) / deploy-time (verdict)** | OSCAL 1.1.2 valid; Rego compiles + evaluates; PASS/FAIL needs live cluster |
| SLSA Build **L1** | **REAL (honest baseline)** | |
| SLSA Build **L1** (honest) on 5 organ images; **L2 roadmap** | **REAL (L1)** | cosign `.sig` on organ images; L2 `.att` attestation not yet earned |
| Bundle-level attestation | **NOT earned (ROADMAP)** | cosign **signature** = bundle provenance only; not L3, not Iron Bank, no FedRAMP/CMMC |
| Doctrine v11 | **LOCKED** | 749 theorems / 14 axioms / 163 definitions @ `958c09f9` |
| Λ (conjunctive gate) | **Conjecture 1** | not a theorem; agentic P1–P6 CI-green on `main @ 958c09f9` |
| cannonico vertical | **REAL** | other verticals are sample/illustrative |
| Section 889 vendor list | **REAL** | exactly 5: Huawei, ZTE, Hytera, Hikvision, Dahua |

### Re-probed GHCR digests (anonymous token + manifest HEAD, 2026-06-06)

| Image / tag | Digest | Status |
| --- | --- | --- |
| `szl-mesh:0.4.0` | `sha256:7f5fce32…cac7f` | **VERIFIED** (200) |
| `killinchu-bundle:0.5.0` | `sha256:e5992133…7426f` | **VERIFIED CURRENT** (200) |
| `a11oy-bundle:0.5.0` | `sha256:d801f8e4…d64b51` | **STALE** (200, built against old a11oy) |
| `a11oy:uds-v0.2.0` | `sha256:99e4ded1…f719cf` | **VERIFIED** (200; digest changed from roadmap → confirms rebuild) |
| `sentra:uds-v0.2.0` | `sha256:60a0efc1…ac3639` | **VERIFIED** (200) |
| `amaru:uds-v0.2.0` | `sha256:53301e26…b289ff` | **VERIFIED** (200) |
| `yupana:uds-v0.2.0` | `sha256:1984a15f…302848` | **VERIFIED** (200) |
| `killinchu:uds-v0.2.0` | `sha256:e0fb6c3a…29ca548` | **VERIFIED** (200) |
| `a11oy:0.5.0(-wolfi)`, `a11oy-ledger:0.5.0`, `killinchu:0.5.0-wolfi`, `killinchu-relay:0.5.0`, `szl-pepr-governance:0.5.0`, `szl-lula-runner:latest` | — | **404 — NOT published → verify before deploy** |

---

## 6. Allodial posture — what SZL holds *outright*

> **What "allodial" means here, and what it does NOT mean.**
> [Allodial title](https://en.wikipedia.org/wiki/Allodial_title) is the legal concept of
> property held **free and clear, owing no feudal duty to a superior** (cf. the limited
> statutory form in [Nevada NRS 361.900–361.920](https://www.leg.state.nv.us/nrs/nrs-361.html)).
> We borrow it **only as an engineering metaphor** for *who can revoke or interfere with the
> running substrate*. **We explicitly REJECT the sovereign-citizen "land-patent" framing** —
> this section makes no legal claim of any kind; it is a deployment-control posture, not a deed.
> Consistent with the [World Economic Forum framing of digital sovereignty](https://www.weforum.org/agenda/2021/03/europe-digital-sovereignty/),
> "sovereignty" here is **operational control of data, infrastructure, and the chain of title over artifacts** — nothing more.

This posture is **PROPOSED**, not a formal result. It is **not** a theorem and **not** part of
Doctrine Λ (which remains **Conjecture 1**, advisory only). Trust in any layer is **never 100%**.

### Three layers we hold outright (today)

| Layer | What is held allodially | Honest status |
| --- | --- | --- |
| **1 — Mesh & images** | The UDS mesh runs on our own substrate; organ images are **signed** (cosign `.sig`) and pinned by digest, so no upstream party can silently swap what we run. | **REAL (L1 signing)** — L2 attestation on roadmap (see §5). |
| **2 — Chain of title** | Provenance of every artifact via [in-toto](https://in-toto.io/) attestations, [SLSA](https://slsa.dev/) build levels, [Sigstore/cosign](https://www.sigstore.dev/) signatures, and a [Rekor](https://docs.sigstore.dev/logging/overview/) transparency-log entry — a cryptographic record of *where each artifact came from*. | **REAL (L1) / partial** — cosign signatures + Rekor inclusion are live; full DSSE verify + SLSA **L2** is roadmap (P1). |
| **3 — Local data & model** | Inference data and model weights live on local/self-hosted infrastructure; no required runtime call to a third-party control plane to keep serving. | **REAL** for the local serving path; external compute (when used) is flagged. |

### The L6 differentiator (PROPOSED)

Industry sovereignty / supply-chain maturity is commonly described across roughly **L1–L5**
(signing → provenance → hardened builds → org-isolated builds → reproducible/hermetic builds),
the spine of which is the public [SLSA](https://slsa.dev/spec/v1.0/levels) ladder. **We propose an
additional posture — "L6" — a machine-checked *cryptographic chain-of-title receipt*:** a single
verifiable artifact that binds (a) the signed image digest, (b) its in-toto/SLSA provenance, and
(c) its Rekor inclusion proof into one receipt a relying party can check **offline against a pinned
trust root**. To our knowledge **no mainstream toolchain operationalizes this L6 receipt today** —
the L1–L5 building blocks exist and are widely deployed, but the *consolidated, independently
re-verifiable chain-of-title receipt* is the differentiator we are pursuing.

> **L6 is a PROPOSED SZL posture, not an industry standard and not a claimed certification.**
> It does not imply FedRAMP, CMMC, Iron Bank, or SLSA L3+ — those are not achieved and remain on the roadmap (unearned; see §5).

### Honest limit

We do **not** hold the *entire* stack allodially. The substrate still depends on third-party
**hardware**, the **AGPL-3.0 UDS toolchain** (interoperate-only — see License split), upstream
**base images**, and — when used — **external compute and model providers**. The L6 receipt is
**designed but not yet fully operationalized**: today we have cosign signatures and Rekor inclusion
(L1), with the consolidated offline-verifiable receipt and SLSA **L2** attestation on the roadmap.
Any claim beyond "signed + provenance-tracked, locally servable" is **roadmap, labelled honestly**.

---

## 7. License split

| Component | License | How we use it |
| --- | --- | --- |
| Zarf | Apache-2.0 | Packaging engine — embeddable with NOTICE |
| Pepr | Apache-2.0 | Admission module API — embeddable with NOTICE |
| lula1 / go-oscal | Apache-2.0 | Compliance engine + OSCAL libs — Apache-2.0 |
| OPA / Rego | Apache-2.0 | Policy language used by lula opa provider |
| **uds-core** (UDS Operator) | **AGPL-3.0** | **Interoperate only** — we write CRs that target it |
| **uds-cli** | **AGPL-3.0** | **Interoperate only** — we invoke the binary |
| **uds-common** | **AGPL-3.0** | **Interoperate only** |
| **maru-runner** | **AGPL-3.0** | **Interoperate only** |

All SZL-authored artifacts in this repo (Package CRs, Zarf/Bundle YAML, Pepr capability,
OSCAL + Rego) are **Apache-2.0**.

---

## 8. What requires the live Hetzner/tower environment

These can only be truly verified at **deploy time** (no bandaids — flagged honestly):

- Full `uds deploy` reconcile of the Package CRs by the UDS Operator.
- Pepr admission webhook **live admit/deny** round-trip in a k3d/UDS cluster.
- `lula validate` control **PASS/FAIL** verdicts against live cluster state
  (offline they correctly report `not-satisfied`).
- `cosign verify` of organ-image `.sig`/`.att` (needs network to Rekor).
- Re-publish + re-verify of the **stale** `a11oy-bundle:0.5.0`.
- Publication of the `0.5.0` / `0.5.0-wolfi` / `szl-pepr-governance` images (currently 404).
