<!-- SPDX-License-Identifier: Apache-2.0 -->
# Warhacker Rubric Scorecard + Honest Gap Analysis — 2026-06-16 (supersedes 2026-06-15)

**Author:** Forge (SZL Holdings CTO/engineer)
**Box:** 167.233.50.75 · repo `/opt/szl/szl-uds-deployment` @ main `5dd7e22`
**Event:** Warhacker demo, 2026-06-18 · warhacker.dev rubric (100 pts)
**Doctrine:** v11 — honest labels; never fake, never weaken a gate, never commit a key, never fabricate joules. Honest BLOCKED beats fake.

> **Trademark notice.** "UDS" references Defense Unicorns' Unified Defense Stack (USPTO Serial 99831122). SZL Holdings is not affiliated with Defense Unicorns; contributions are made via upstream PRs. https://defenseunicorns.com/uds

## What changed since 2026-06-15 (gaps now CLOSED — verified, not asserted)
- **Bundle is LIVE, not roadmap.** `oci://ghcr.io/szl-holdings/szl-uds-bundle:uds-v0.3.0`
  is **published** (also `:0.3.0` / `:latest`) and carries, on ghcr, a keyless cosign
  **signature** (`*.sig`) AND a SLSA-provenance **attestation** (`*.att`). The
  earlier "publish+sign pending — ROADMAP" caveat is retired.
- **SLSA L1+L2 EARNED at the bundle level (closes old Gap 5).** `uds-bundle-publish.yml`
  signs keyless (Fulcio/Rekor via GitHub OIDC — no `attestations:write` needed) and
  `cosign attest --type slsaprovenance` + `--type spdxjson`; `prove-bundle` and
  `prove-coboot` HARD-GATE on `cosign verify-attestation` for both predicate types
  against the exact publisher OIDC identity. L3 remains roadmap.
- **Field-airgap PROVEN (A1).** prove-bundle/prove-coboot run an AIRGAP AUDIT that
  asserts every workload image (init + Istio sidecars included) resolves to the
  in-cluster Zarf registry (no external pull) and is digest-pinned. Scope: the FIELD
  install is airgapped; the BUILD/substrate phase has network.
- **prove-coboot GREEN (headline Death-Proof).** Run 27592855545: a11oy + killinchu
  CO-BOOT on ONE clean k3d cluster from the *published, cosign-verified,
  attestation-gated, airgap-audited* bundle; both serve in-cluster HTTP 200. Honest
  scope: the TWO consolidated deployables, NOT the legacy 5-organ fleet.

## Rubric mapping (100 pts; target 50/50 in the two 25% pillars)

| Criterion | Weight | Honest state (2026-06-16) |
|---|---|---|
| Mission Impact | 25% | STRONG — individually-deployable signed organs; a11oy real UI, killinchu vessels/sanctions |
| Portability | 25% | STRONG — digest-pinned bundle **published + keyless-signed + SBOMed + SLSA-attested**, installs on any UDS Core; small-box overrides. Standalone/full-fleet breadth = rosie-blocked gap |
| Death Proof | 25% | STRONG — **prove-coboot GREEN** (cosign-verify + verify-attestation + airgap gates) + receipts/Prometheus/Grafana + guard suite. prove-bundle-install 4/5 green, rosie blocked |
| Most Resourceful | 15% | STRONG — full UDS Core on an 8 GB box; throwaway-k3d prove harness; build/sign/attest pushed to keyless CI |
| Judges Pick | 10% | STRONG — doctrine-v11 honesty (SAMPLE joules, BLOCKED-not-faked, no real ATO), trademark hygiene |

## Honest gaps — "what's missing / make it real"
1. **rosie organ image is broken (the one real blocker).** prove-bundle-install #30
   (run 27592186983) proved 4/5 organs install→health-200 from the published, signed,
   attested bundle (a11oy, killinchu, amaru, sentra — ALL gates PASS). **rosie** fails:
   `python: can't open file '/home/user/app/app.py': [Errno 13] Permission denied`
   → `szl-rosie` Deployment never reaches Available. The fault is baked into the
   prebuilt image `ghcr.io/szl-holdings/rosie:uds-v0.2.0@sha256:1984a15f…` (no in-repo
   Dockerfile — the image is built elsewhere). **Close:** rebuild the rosie image so
   `app.py` is world-readable / owned by the runtime user, repush, repin, recut+
   republish. *Deferred here — contended (touches the published bundle + an external
   image); not faked, not gate-weakened (rosie stays in the matrix and honestly red).*
2. **prove-organs nightly glob bug — FIXED (commit `5dd7e22`).** The 07:00 nightly had
   failed 4 straight nights (06-12…06-15), every leg dying at the substrate step with
   `ERROR: no uds-bundle-szl-prove-substrate-*.tar.zst found after build` because
   `tasks/prove-organs.yaml` globbed CWD instead of `bundles/prove-organs/` (the
   `uds create` output dir). One-line mirror of the proven `2fee13d` prove-bundle fix.
   After this, a11oy/killinchu/amaru/sentra legs proceed; the only remaining
   prove-organs red is the SAME rosie image bug above (honest, not a harness lie).
3. **Standalone / full-fleet breadth.** The consolidated `szl-uds-bundle:uds-v0.3.0`
   already carries a11oy + killinchu as **un-staged real members** (done by the active
   publisher); `szl-warhacker` has a11oy + killinchu un-staged with amaru/sentra
   honestly STAGED. A clean all-5 fleet prove-install is blocked only by rosie (gap 1).
4. **Energy MEASURED joules (roadmap).** On-box NVML exporter + signed JouleCharge
   chain. Until then: honestly SAMPLE, asserted live from the payload `/fabric`.
5. **SLSA L3 / ATO.** L1+L2 earned (above); L3 roadmap; ATO-aligned roadmap only —
   never a real ATO.

## Honest status labels (keep verbatim)
- **SAMPLE** joules — never MEASURED without a real NVML meter.
- **BLOCKED-on-key** file-signing — keyless CI OIDC is the real signing path.
- **No real ATO** — ATO-aligned roadmap only.

## Verdict
The two 25% pillars are now carried by a **published, keyless-signed, SBOMed,
SLSA-provenance-attested, field-airgap-audited** UDS bundle that **co-boots a11oy +
killinchu on a clean UDS Core** with every gate green (prove-coboot 27592855545).
The single honest blocker to the full 5-organ claim is the rosie image perms bug;
energy stays SAMPLE and SLSA-L3/ATO stay roadmap — labeled, never faked.
