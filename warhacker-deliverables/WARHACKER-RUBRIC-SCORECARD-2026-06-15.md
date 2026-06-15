<!-- SPDX-License-Identifier: Apache-2.0 -->
# Warhacker Rubric Scorecard + Honest Gap Analysis — 2026-06-15

**Author:** Forge (SZL Holdings CTO/engineer)
**Box:** 167.233.50.75 · repo `/opt/szl/szl-uds-deployment` @ main `ebb55ca`
**Event:** Warhacker demo, 2026-06-18 · warhacker.dev rubric (100 pts)
**Doctrine:** v11 — honest labels; never fake, never weaken a gate, never commit a key, never fabricate joules. Honest BLOCKED beats fake.

> **Trademark notice.** "UDS" references Defense Unicorns' Unified Defense Stack (USPTO Serial 99831122). SZL Holdings is not affiliated with Defense Unicorns; contributions are made via upstream PRs. https://defenseunicorns.com/uds

## Scope
Maps the shipped SZL UDS payload set to the five Warhacker judging criteria, points
each claim at LIVE evidence, and lists the honest gaps plus the exact action to
close each one ("make it real"). Additive report file only — no mutation of the
live cluster or the published artifacts.

## The published evidence (what a judge can pull today)
- **Bundle:** `oci://ghcr.io/szl-holdings/szl-uds-bundle:uds-v0.3.0`
  @ `sha256:e61c2f9880560ec71812f546b9bad09de4b9d58ad15b27968cb9cf23dd6a4f4a`
  — five mission organs (a11oy, killinchu, amaru, sentra, rosie).
- **Signature:** keyless cosign (GitHub OIDC → Fulcio + Rekor). `cosign verify`
  PASSES against the publisher workflow identity (verified in `prove-bundle-install`
  run logs). No `COSIGN_PRIVATE_KEY` is provisioned on the box → file-signing is
  honestly **BLOCKED-on-key**; keyless OIDC in CI is the signing path that actually
  runs.
- **SBOM:** attached to the published bundle.
- **Pull path:** anonymous `uds pull oci://…:uds-v0.3.0` succeeds (the customer fetch).

## Rubric mapping (100 pts; Rosa's target: 50/50 = max in the two 25% pillars)

| Criterion | Weight | Primary evidence | Honest state |
|---|---|---|---|
| Mission Impact | 25% | five individually-deployable mission organs; a11oy serves a real UI, killinchu serves vessels/sanctions | STRONG |
| Portability | 25% | published, keyless-signed, SBOMed, **digest-pinned** UDS bundle; pulls + installs on any UDS Core; small-box overrides | STRONG (5-organ bundle) — standalone organ `.uds` = gap |
| Death Proof | 25% | receipts chain + Prometheus/Grafana; guard suite; keyless signing + SBOM; `prove-bundle-install` (cosign GATE → k3d install → health 200) | STRONG once `prove-bundle-install` nightly is green |
| Most Resourceful | 15% | full UDS Core on an 8 GB box (istiod autoscaleMax=1, ClusterIP gateway); throwaway-k3d prove harness | STRONG |
| Judges Pick | 10% | doctrine-v11 honesty (SAMPLE joules, BLOCKED-not-faked), trademark hygiene, OSCAL/Lula roadmap | STRONG |

### 1. Mission Impact (25%)
SZL ships **mission software as individually-deployable, signed UDS organs** — the
unit a defense/edge mission actually needs: pull one signed bundle, install on
whatever UDS Core cluster the mission has, get a working service. Organs in
`szl-uds-bundle:uds-v0.3.0`:
- **a11oy** — sovereign AI / compliance mesh; serves a real UI (HTTP 200 through the
  Istio admin gateway, proven live in k3d `uds-szl-demo`).
- **killinchu** — maritime / sanctions / vessels surface (`GET /vessels` and
  `GET /sanctions` → 200 on the running organ).
- **amaru, sentra, rosie** — additional mission organs, each an individually
  deployable UDS package (templated `###ZARF_PKG_TMPL_VERSION###`, built per-organ).

The impact is *operational sovereignty*: signed, portable, auditable mission
capability that runs disconnected / at the edge — not a slide deck.

### 2. Portability (25%)
The **UDS bundle is the portability evidence.** `szl-uds-bundle:uds-v0.3.0` is a
single OCI artifact, every layer **digest-pinned** (init, core-base, the organs),
keyless-signed and SBOMed, and anonymously pullable. It installs onto any UDS Core
cluster — and the small-box overrides (istiod `autoscaleMax=1`, `pilot.cpu=150m`,
tenant gateway `ClusterIP`) let it run where the mission's hardware is constrained,
down to an 8 GB box. Live proof: a11oy reachable at HTTP 200 through the Istio
gateway on a real k3d cluster.

### 3. Death Proof (25%)
Crossing the valley of death = the artifact keeps proving itself, signed and
observable, on a clean cluster — automatically.
- **Signing + SBOM:** keyless cosign (Fulcio/Rekor); SBOM attached; `cosign verify`
  GATE is a LOUD-fail step inside `prove-bundle-install`.
- **prove-bundle-install:** for each organ — cosign-verify the published signature →
  cold k3d cluster → stand up UDS substrate → deploy the organ from the *pulled,
  published* bundle → assert in-cluster health 200. Runs on schedule (08:00 UTC).
- **Receipts chain + observability:** signed receipt chain with Prometheus/Grafana
  (see `RECEIPT-CHAIN-OBSERVABILITY` + `RECEIPTS-PROMETHEUS-GRAFANA-LIVE`).
- **Guard suite (all PASS):** version-doctrine, organ/pin-drift, image-stale-watch,
  bundle-digest-watch/recut, oci-ref, deploy-entry, clean-deploy, bundle-build-guard,
  catalog-validation — plus guard self-tests.

*Honest status (2026-06-15):* the cosign signature GATE PASSES. Two **pre-existing**
`prove-bundle-install` harness bugs were fixed on `main` today — substrate
build-output path (`2fee13d`) and substrate-deploy `--skip-signature-validation`
(`ebb55ca`) — and the all-five-organ install→health-200 proof is re-running on the
fixed `main`. The durable Death-Proof signal is this run going green and the nightly
schedule staying green (tracked in Gaps §1).

### 4. Most Resourceful (15%)
A full UDS Core (Istio, Keycloak, Pepr, Falco, Loki, kube-prometheus-stack) plus an
SZL organ runs on an 8 GB / ~2 vCPU box via deliberate rightsizing overrides, and
the install proof uses **throwaway** k3d clusters so the prod box is never put at
risk. Build/sign/publish/prove are pushed onto isolated CI runners (keyless OIDC),
keeping the constrained prod box for serving.

### 5. Judges Pick (10%)
Polish + honesty: doctrine-v11 labels are enforced, not decorative — joules are
**SAMPLE** (never faked MEASURED), file-signing is **BLOCKED-on-key** (not a fake
key), STAGED means not-yet-pushed, and there is **no real ATO** (ATO-aligned
roadmap only). Trademark hygiene on "UDS" throughout. OSCAL/Lula compliance is an
honest roadmap, not a forged attestation.

## Energy honesty (joules = SAMPLE, gated by a LIVE check — never hardcoded)
The `bundles/energy` payload labels its joules **SAMPLE**, and that label is read
**live** from the payload's own `/fabric` endpoint — `prove-it.sh` asserts
`joules_label == "SAMPLE"` and `sovereign == false` against the running signal. There
is **no on-box NVML joule exporter** in this payload, so it does **not** emit
MEASURED-joule signed "JouleCharge" receipts — that is ROADMAP. The label is driven
by the live `/fabric` reading, not a constant: it stays SAMPLE until a real NVML
meter is wired, and the prove-it gate FAILS LOUD if anything ever claims MEASURED
without the meter.

## Honest gaps — "what's missing / make it real"
1. **`prove-bundle-install` nightly GREEN (Death Proof).** Two pre-existing harness
   bugs fixed on `main` today (`2fee13d`, `ebb55ca`); the all-organ
   install→health-200 proof is re-running on the fixed `main`.
   **Close:** confirm the run is green, then keep the 08:00 UTC schedule green.
2. **`tasks/prove-organs.yaml` has the IDENTICAL substrate glob bug** — it globs the
   repo root instead of `bundles/prove-organs/`, so the 07:00 nightly `prove-organs`
   will keep failing until the same one-line fix lands.
   **Close:** mirror the `2fee13d` fix into `tasks/prove-organs.yaml` (Eng-owned
   workflow — coordinate before pushing).
3. **Standalone organ `.uds` bundles (Portability breadth).** The published
   standalone `a11oy-bundle`/`killinchu-bundle:0.5.0` are stale (06-06), and
   `bundles/{a11oy,killinchu}` version-coherence needs reconcile (`packages/a11oy/
   zarf.yaml` is literal `0.5.0-uds.0` while bundle refs differ); `szl-full-stack`
   (0.3.1) refs a11oy 0.2.0 and is unpublished (404); `szl-warhacker` (0.4.0) organs
   are staged/commented.
   **Close:** reconcile versions, then recut + publish via the keyless CI publisher.
   *(Contended file surface — coordinate with the active publisher work before
   pushing.)*
4. **Energy MEASURED joules (roadmap).** On-box NVML exporter + signed JouleCharge
   receipt chain. Until then: honestly SAMPLE.
5. **SLSA / ATO.** L1 honest, L2 where `attest-build-provenance` runs + `cosign
   verify-attestation` succeeds, L3 roadmap; ATO-aligned roadmap only — never a real
   ATO. Bundle-level build-provenance is not earned (CI token lacks
   `attestations:write`); the cosign signature is the bundle provenance.

## Live deploy proof already in hand (independent of the CI harness)
From `UDS-ECOSYSTEM-ALIGNMENT-AND-DEPLOY-PROOF-2026-06-15.md`: in live k3d
`uds-szl-demo`, **a11oy returns HTTP 200 (real UI) through the Istio admin gateway**
(full external → mesh → pod path), killinchu 307 (up, redirecting), receipts-server
alive. A real, reproducible install→serve proof on UDS Core today — separate from
the CI prove harness.

## Honest status labels (keep verbatim)
- **SAMPLE** joules — never MEASURED without a real NVML meter.
- **BLOCKED-on-key** file-signing — keyless CI OIDC is the real signing path.
- **STAGED** — until the images are pushed + signed.
- **No real ATO** — ATO-aligned roadmap only.

## Verdict
The two 25% pillars (Portability, Death Proof) are carried by a **published,
keyless-signed, SBOMed, digest-pinned UDS bundle** that installs on a clean UDS Core
cluster, plus a live a11oy-200 deploy proof and a receipts / guard / observability
spine. To lock 50/50 in those pillars: (1) confirm `prove-bundle-install` green on
the fixed `main` and keep the nightly green, (2) fix the twin `prove-organs`
substrate bug, (3) reconcile + publish the standalone organ `.uds` bundles.
Everything else maps to Mission Impact / Most Resourceful / Judges Pick with honest,
non-faked evidence. Energy stays SAMPLE by live `/fabric` check.
